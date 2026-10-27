import Foundation
import CoreGraphics

// MARK: - Input types

nonisolated struct ProcessorSettings {
    var optimize = OptimizeSettings()
    var compress = CompressSettings()
    var convert = ConvertSettings()
    var resize = ResizeSettings()
    var rotate: RotateOperation = .right90
}

nonisolated struct ImageJob {
    let url: URL
    let byteSize: Int64
    /// Pixel size after auto-orient. Only needed for Crop.
    var pixelSize: CGSize? = nil
    /// Crop rectangle in oriented image pixels. Only needed for Crop.
    var cropRect: CGRect? = nil
}

// MARK: - The engine

/// Everything that turns "an image + an action + settings" into a magick run.
/// It has no UI state, so the main window, the folder watcher and the Finder services all share it.
nonisolated struct ImageProcessor {
    let runner: MagickRunner
    var writableFormats: Set<String> = []

    nonisolated struct Plan {
        let ext: String
        let suffix: String
        let note: String
        let arguments: (_ input: String, _ output: String) -> [String]
    }

    // MARK: Planning (everything except Compress)

    static func makePlan(action: ImageAction,
                         settings: ProcessorSettings,
                         job: ImageJob,
                         writableFormats: Set<String>) throws -> Plan {
        let inExt = job.url.pathExtension.lowercased()
        let isHEIC = inExt == "heic" || inExt == "heif"
        // We never write HEIC from these actions (encoder support varies), so HEIC becomes JPG.
        let sameExt = isHEIC ? "jpg" : inExt
        let heicNote = isHEIC ? "saved as JPG" : ""

        switch action {
        case .compress, .optimize:
            throw MagickError(message: "Compress and Smart optimize don't use a single magick command.")

        case .convert:
            let s = settings.convert
            let ext = s.resolvedExtension
            guard !ext.isEmpty else { throw MagickError(message: "Choose a format to convert to.") }
            guard ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw MagickError(message: "“\(ext)” isn't a valid file extension.")
            }
            guard !ImageFiles.blockedOutputs.contains(ext) else {
                throw MagickError(message: "This app only converts to image formats.")
            }
            if !writableFormats.isEmpty && !writableFormats.contains(ext.uppercased()) {
                throw MagickError(message: "Your ImageMagick can't write .\(ext) files.")
            }
            let lossy = ImageFiles.lossyOutputs.contains(ext)
            let flatten = ImageFiles.noAlphaOutputs.contains(ext)
            let sameFormat = ImageFiles.normalizedExtension(ext) == ImageFiles.normalizedExtension(inExt)
            return Plan(ext: ext, suffix: sameFormat ? "_converted" : "", note: "") { input, output in
                var args = [input, "-auto-orient"]
                if flatten { args += ["-background", "white", "-alpha", "remove", "-alpha", "off"] }
                if lossy { args += ["-quality", String(Int(s.quality))] }
                args.append(output)
                return args
            }

        case .crop:
            guard let size = job.pixelSize else {
                throw ItemSkip(message: "Image size isn't known yet. Try again in a moment.")
            }
            guard let r = job.cropRect else {
                throw ItemSkip(message: "No crop set for this image.")
            }
            let width = Int(size.width)
            let height = Int(size.height)
            let x = min(max(0, Int(r.minX.rounded())), width - 1)
            let y = min(max(0, Int(r.minY.rounded())), height - 1)
            let w = min(max(1, Int(r.width.rounded())), width - x)
            let h = min(max(1, Int(r.height.rounded())), height - y)
            if x == 0 && y == 0 && w == width && h == height {
                throw ItemSkip(message: "The crop covers the whole image.")
            }
            let geometry = "\(w)x\(h)+\(x)+\(y)"
            return Plan(ext: sameExt, suffix: action.suffix, note: heicNote) { input, output in
                // -auto-orient first, so the crop coordinates match what you saw.
                [input, "-auto-orient", "-crop", geometry, "+repage", output]
            }

        case .resize:
            let s = settings.resize
            let geometry: String
            if s.mode == .percent {
                geometry = "\(max(1, Int(s.percent)))%"
            } else {
                let w = max(0, Int(s.width))
                let h = max(0, Int(s.height))
                if w == 0 && h == 0 { throw MagickError(message: "Enter a width or a height.") }
                var g = (w > 0 && h > 0) ? "\(w)x\(h)" : (w > 0 ? "\(w)" : "x\(h)")
                if w > 0 && h > 0 && !s.keepAspect {
                    g += "!"
                } else if s.shrinkOnly {
                    g += ">"
                }
                geometry = g
            }
            return Plan(ext: sameExt, suffix: action.suffix, note: heicNote) { input, output in
                [input, "-auto-orient", "-resize", geometry, output]
            }

        case .rotate:
            let operation = settings.rotate
            return Plan(ext: sameExt, suffix: action.suffix, note: heicNote) { input, output in
                [input, "-auto-orient"] + operation.arguments + [output]
            }

        case .metadata:
            return Plan(ext: sameExt, suffix: action.suffix, note: heicNote) { input, output in
                // -auto-orient first, because -strip also deletes the orientation tag.
                [input, "-auto-orient", "-strip", output]
            }
        }
    }

    // MARK: Running

    /// Processes one image. The result is written to `outputDirectory`, or next to the original when nil.
    /// Throws `ItemSkip` when there is nothing to do, and `MagickError` on failure.
    func process(job: ImageJob,
                 action: ImageAction,
                 settings: ProcessorSettings,
                 outputDirectory: URL?,
                 reserved: inout Set<String>) async throws -> ItemStatus {
        if action == .optimize {
            return try await optimize(job: job, settings: settings.optimize,
                                      outputDirectory: outputDirectory, reserved: &reserved)
        }
        if action == .compress {
            return try await processCompress(job: job, settings: settings.compress,
                                             outputDirectory: outputDirectory, reserved: &reserved)
        }

        let plan = try Self.makePlan(action: action, settings: settings, job: job, writableFormats: writableFormats)
        let stem = OutputNaming.sanitize(job.url.deletingPathExtension().lastPathComponent) + plan.suffix
        let directory = outputDirectory ?? job.url.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory: directory, stem: stem, ext: plan.ext, reserved: &reserved)

        let runner = self.runner
        _ = try await InputResolver.withPaths([job.url]) { paths in
            try await runner.run(plan.arguments(firstFrame(paths[0]), output.path))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MagickError(message: "magick finished but no output file was created.")
        }
        return .done(output: output, inBytes: job.byteSize, outBytes: fileSize(output), note: plan.note)
    }

    private func processCompress(job: ImageJob,
                                 settings: CompressSettings,
                                 outputDirectory: URL?,
                                 reserved: inout Set<String>) async throws -> ItemStatus {
        let target = settings.targetBytes
        guard target > 0 else { throw MagickError(message: "Enter a target size above 0.") }

        let inExt = ImageFiles.normalizedExtension(job.url)
        let outExt: String
        switch settings.format {
        case .keep: outExt = ["jpg", "png", "webp"].contains(inExt) ? inExt : "jpg"
        case .jpg: outExt = "jpg"
        case .webp: outExt = "webp"
        }

        if outExt == inExt && job.byteSize <= target {
            throw ItemSkip(message: "Already \(formatBytes(job.byteSize)), under the target.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let runner = self.runner
        let strip = settings.stripMetadata
        let result = try await InputResolver.withPaths([job.url]) { paths in
            try await SizeCompressor(runner: runner).compress(
                inputPath: paths[0], ext: outExt, targetBytes: target, strip: strip, workDir: workDir)
        }

        let stem = OutputNaming.sanitize(job.url.deletingPathExtension().lastPathComponent) + ImageAction.compress.suffix
        let directory = outputDirectory ?? job.url.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory: directory, stem: stem, ext: outExt, reserved: &reserved)
        try FileManager.default.moveItem(at: result.file, to: output)

        var note = result.note
        if outExt != inExt { note += ", saved as \(outExt.uppercased())" }
        return .done(output: output, inBytes: job.byteSize, outBytes: result.bytes, note: note)
    }
}

// MARK: - Marking files we've already optimized

/// A hidden extended attribute on files the app has written, so the folder watcher never
/// processes its own output (or the same file twice).
nonisolated enum ProcessedMarker {
    static let attributeName = "com.magickui.processed"

    static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, ProcessedMarker.attributeName, nil, 0, 0, 0) >= 0
        }
    }

    static func mark(_ url: URL) {
        let value: [UInt8] = [1]
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = value.withUnsafeBytes { buffer in
                setxattr(path, ProcessedMarker.attributeName, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
    }
}

// MARK: - Replacing an original in place

nonisolated enum OriginalHandling: String, CaseIterable, Identifiable, Codable {
    case trash = "Move the original to the Trash"
    case overwrite = "Overwrite the original"

    var id: String { rawValue }
}

nonisolated enum InPlaceFinalizer {
    /// Puts `processed` where `original` was. Returns the final location.
    /// If the format changed (e.g. HEIC -> JPG), the new file gets the new extension and the
    /// original goes to the Trash, whichever option is chosen.
    static func finalize(original: URL, processed: URL, handling: OriginalHandling) throws -> URL {
        let fm = FileManager.default
        let directory = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        let newExt = processed.pathExtension
        let sameFormat = newExt.lowercased() == original.pathExtension.lowercased()

        let destination: URL
        if sameFormat {
            destination = original
        } else {
            var reserved = Set<String>()
            destination = OutputNaming.uniqueURL(directory: directory, stem: stem, ext: newExt, reserved: &reserved)
        }

        if sameFormat && handling == .overwrite {
            _ = try fm.replaceItemAt(original, withItemAt: processed)
        } else {
            // Trash the original first, then move the new file in. If the move fails, put the original back.
            var trashed: NSURL?
            try fm.trashItem(at: original, resultingItemURL: &trashed)
            do {
                try fm.moveItem(at: processed, to: destination)
            } catch {
                if let trashedURL = trashed as URL? {
                    try? fm.moveItem(at: trashedURL, to: original)
                }
                throw error
            }
        }

        ProcessedMarker.mark(destination)
        return destination
    }
}

// MARK: - Collecting image files from dropped / selected URLs

extension ImageFiles {
    /// Expands folders (recursively) and keeps only supported images.
    nonisolated static func collect(from urls: [URL]) -> (files: [URL], skipped: Int) {
        var files: [URL] = []
        var seen = Set<String>()
        var skipped = 0

        func consider(_ url: URL) {
            guard accepted.contains(url.pathExtension.lowercased()) else { skipped += 1; return }
            if seen.insert(url.path).inserted { files.append(url) }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let found = (enumerator?.allObjects as? [URL]) ?? []
                for item in found.sorted(by: { $0.path < $1.path }) { consider(item) }
            } else {
                consider(url)
            }
        }
        return (files, skipped)
    }
}
