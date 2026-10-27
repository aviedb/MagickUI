import Foundation

// MARK: - Settings

nonisolated enum OptimizeLevel: String, CaseIterable, Identifiable, Codable {
    case balanced = "Balanced"
    case aggressive = "Aggressive"
    case custom = "Custom"

    var id: String { rawValue }
}

/// "Smart optimize": shrink files without ever changing their dimensions.
nonisolated struct OptimizeSettings: Codable {
    var level: OptimizeLevel = .balanced
    /// Used only when `level` is `.custom`. Scale: 5 = best quality, 100 = smallest file.
    var customFactor: Int = 45
    var stripMetadata = true
    /// HEIC, TIFF and BMP are saved as JPG, which opens everywhere.
    var convertIncompatible = true

    var factor: Int {
        switch level {
        case .balanced: return OptimizeCurves.normalFactor
        case .aggressive: return OptimizeCurves.aggressiveFactor
        case .custom: return min(100, max(5, customFactor))
        }
    }
}

// MARK: - Compression curves

/// One "strength" number (5 = best quality, 100 = smallest file) is turned into settings for
/// jpegoptim and pngquant. Balanced is 30 and Aggressive is 64.
///
/// The curve is tuned so Balanced caps JPEG quality at 85 and Aggressive at 58, which keeps photos
/// looking the same at normal viewing size while still giving a clear size reduction.
nonisolated enum OptimizeCurves {
    static let normalFactor = 30
    static let aggressiveFactor = 64

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        max(low, min(high, value))
    }

    /// jpegoptim --max. Factor 30 -> 85, factor 64 -> 58, factor 100 -> 18.
    static func jpegMaxQuality(_ factor: Int) -> Int {
        let f = Double(factor)
        if f <= 70 {
            return Int(clamp((85 - (f - 30) * (55.0 / 70.0)).rounded(), 25, 95))
        }
        return Int(clamp((54 - (f - 70) * (36.0 / 30.0)).rounded(), 18, 95))
    }

    /// pngquant --quality 0-N. Factor 30 -> 100, factor 64 -> 64, factor 100 -> 25.
    static func pngQualityMax(_ factor: Int) -> Int {
        let f = Double(factor)
        return Int(clamp((100 - (f - 30) * (75.0 / 70.0)).rounded(), 25, 100))
    }

    /// pngquant palette size, only from factor 80 up. Otherwise pngquant's default of 256.
    static func pngColors(_ factor: Int) -> Int? {
        guard factor >= 80 else { return nil }
        return Int(clamp(224 - Double(factor - 80) * 8, 64, 256))
    }

    /// pngquant --speed. Slower speeds search harder for a small palette.
    static func pngSpeed(_ factor: Int) -> Int {
        factor < 40 ? 4 : factor < 60 ? 3 : factor < 85 ? 2 : 1
    }
}

// MARK: - Finding the command-line tools

nonisolated enum ExternalTool {
    /// Looks for a Homebrew-installed tool. (A double-clicked app doesn't inherit your shell PATH.)
    static func locate(_ name: String) -> URL? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static var jpegoptim: URL? { locate("jpegoptim") }
    static var pngquant: URL? { locate("pngquant") }
}

// MARK: - The optimizer

nonisolated extension ImageProcessor {
    /// Optimizes one image without resizing it. See `OptimizeSettings`.
    /// Throws `ItemSkip` when the file can't get any smaller.
    func optimize(job: ImageJob,
                  settings: OptimizeSettings,
                  outputDirectory: URL?,
                  reserved: inout Set<String>) async throws -> ItemStatus {
        let inExt = ImageFiles.normalizedExtension(job.url)
        let factor = settings.factor

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-optimize", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let outExt: String
        let note: String
        let sameFormat: Bool
        let workFile: URL

        switch inExt {
        case "jpg":
            outExt = job.url.pathExtension.lowercased()      // keep .jpg / .jpeg as it was
            sameFormat = true
            workFile = workDir.appendingPathComponent("image.jpg")
            try await prepareJPEG(source: job.url, work: workFile, stripMetadata: settings.stripMetadata)
            note = try await runJpegoptim(workFile, factor: factor, strip: settings.stripMetadata)

        case "png":
            outExt = job.url.pathExtension.lowercased()
            sameFormat = true
            workFile = workDir.appendingPathComponent("image.png")
            note = try await runPngquant(input: job.url, output: workFile, factor: factor)

        case "heic", "tif", "bmp":
            guard settings.convertIncompatible else {
                throw ItemSkip(message: "\(inExt.uppercased()) is left alone (conversion to JPG is off).")
            }
            outExt = "jpg"
            sameFormat = false
            workFile = workDir.appendingPathComponent("image.jpg")
            try await convertToJPEG(source: job.url, work: workFile)
            let jpegNote = try await runJpegoptim(workFile, factor: factor, strip: settings.stripMetadata)
            note = "converted to JPG, " + jpegNote

        case "webp":
            throw ItemSkip(message: "WebP is already efficient, so it's left alone.")

        default:
            throw ItemSkip(message: "This format isn't optimized.")
        }

        let outBytes = fileSize(workFile)
        if sameFormat && outBytes >= job.byteSize {
            throw ItemSkip(message: "Already as small as it can get (\(formatBytes(job.byteSize))).")
        }

        let stem = OutputNaming.sanitize(job.url.deletingPathExtension().lastPathComponent)
            + ImageAction.optimize.suffix
        let directory = outputDirectory ?? job.url.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory: directory, stem: stem, ext: outExt, reserved: &reserved)
        try FileManager.default.moveItem(at: workFile, to: output)

        return .done(output: output, inBytes: job.byteSize, outBytes: outBytes, note: note)
    }

    // MARK: JPEG

    /// Makes the file jpegoptim will work on. If metadata is being removed, the EXIF orientation tag goes
    /// with it, so a rotated photo is rotated for real first (the only time the image is re-encoded here).
    private func prepareJPEG(source: URL, work: URL, stripMetadata: Bool) async throws {
        var needsRotation = false
        if stripMetadata {
            needsRotation = (try? await hasOrientationTag(source)) ?? false
        }
        if needsRotation {
            let runner = self.runner
            _ = try await InputResolver.withPaths([source]) { paths in
                try await runner.run([firstFrame(paths[0]), "-auto-orient", "-quality", "95", work.path])
            }
        } else {
            try FileManager.default.copyItem(at: source, to: work)
        }
    }

    private func hasOrientationTag(_ url: URL) async throws -> Bool {
        let runner = self.runner
        let output = try await InputResolver.withPaths([url]) { paths in
            try await runner.run(["identify", "-format", "%[orientation]", firstFrame(paths[0])])
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(value.isEmpty || value == "Undefined" || value == "TopLeft")
    }

    private func convertToJPEG(source: URL, work: URL) async throws {
        let runner = self.runner
        _ = try await InputResolver.withPaths([source]) { paths in
            try await runner.run([firstFrame(paths[0]), "-auto-orient",
                                  "-background", "white", "-alpha", "remove", "-alpha", "off",
                                  "-quality", "92", work.path])
        }
    }

    /// jpegoptim works in place. With --max it only re-encodes a file whose quality is ABOVE the cap
    /// (otherwise it just optimizes the file losslessly), and it never keeps a result that isn't smaller.
    private func runJpegoptim(_ file: URL, factor: Int, strip: Bool) async throws -> String {
        guard let tool = ExternalTool.jpegoptim else {
            throw MagickError(message: "jpegoptim isn't installed. Run “brew install jpegoptim” in Terminal.")
        }
        let maxQuality = OptimizeCurves.jpegMaxQuality(factor)
        var arguments = ["-q", "--max=\(maxQuality)"]
        if strip {
            arguments += ["--strip-com", "--strip-exif", "--strip-iptc", "--strip-xmp"]
        }
        arguments += ["--", file.path]

        let result = try await MagickRunner(executable: tool).execute(arguments)
        guard result.status == 0 else {
            throw MagickError(message: result.stderr.isEmpty ? "jpegoptim failed (status \(result.status))." : result.stderr)
        }
        return "JPEG quality capped at \(maxQuality)"
    }

    // MARK: PNG

    private func runPngquant(input: URL, output: URL, factor: Int) async throws -> String {
        guard let tool = ExternalTool.pngquant else {
            throw MagickError(message: "pngquant isn't installed. Run “brew install pngquant” in Terminal.")
        }
        let qualityMax = OptimizeCurves.pngQualityMax(factor)
        var arguments = [
            "--quality=0-\(qualityMax)",
            "--speed", String(OptimizeCurves.pngSpeed(factor)),
            "--force", "--skip-if-larger",
            "--output", output.path
        ]
        if let colors = OptimizeCurves.pngColors(factor) {
            arguments.append(String(colors))         // pngquant takes the palette size as a bare number
        }
        arguments += ["--", input.path]

        let result = try await MagickRunner(executable: tool).execute(arguments)
        switch result.status {
        case 0:
            return "PNG quantized (quality 0–\(qualityMax))"
        case 98, 99:
            // 98: the result wasn't smaller. 99: it couldn't reach the minimum quality.
            throw ItemSkip(message: "Already as small as it can get (\(formatBytes(fileSize(input)))).")
        default:
            throw MagickError(message: result.stderr.isEmpty ? "pngquant failed (status \(result.status))." : result.stderr)
        }
    }
}
