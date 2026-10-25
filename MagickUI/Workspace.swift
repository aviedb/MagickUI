import Foundation
import AppKit
import Combine

@MainActor
final class Workspace: ObservableObject {
    let app: AppState

    @Published var items: [ImageItem] = []
    @Published var selectedID: UUID?
    @Published var action: ImageAction?

    @Published var compress = CompressSettings()
    @Published var convert = ConvertSettings()
    @Published var resize = ResizeSettings()
    @Published var rotate: RotateOperation = .right90
    @Published var cropSettings = CropSettings()

    /// Crop rectangle per image, in oriented image pixels.
    @Published var cropRects: [UUID: CGRect] = [:]
    @Published var cropPreview: CGImage?

    @Published var outputFolder: URL?
    @Published var isRunning = false
    @Published var notice: String?
    @Published private(set) var writableFormats: Set<String> = []

    private var reserved = Set<String>()

    init(app: AppState) {
        self.app = app
    }

    // MARK: - Derived

    var selectedItem: ImageItem? {
        items.first { $0.id == selectedID }
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Formats offered as one-tap choices in Convert (filtered to what magick can actually write).
    var convertChoices: [String] {
        let curated = ["jpg", "png", "webp", "heic", "avif", "tiff", "gif", "bmp", "ico", "jp2", "jxl"]
        guard !writableFormats.isEmpty else { return curated }
        return curated.filter { writableFormats.contains($0.uppercased()) }
    }

    var canWriteWebP: Bool {
        writableFormats.isEmpty || writableFormats.contains("WEBP")
    }

    /// How many images the current action would touch.
    var runCount: Int {
        if action == .crop { return items.filter { cropRects[$0.id] != nil }.count }
        return items.count
    }

    var hasResults: Bool {
        items.contains { if case .done = $0.status { return true } else { return false } }
    }

    var commandPreview: String {
        guard let action, action != .compress,
              let item = selectedItem ?? items.first,
              let plan = try? makePlan(action: action, item: item) else { return "" }
        let arguments = plan.arguments(firstFrame(item.url.path), "<output>")
        return (["magick"] + arguments).map(shellQuote).joined(separator: " ")
    }

    // MARK: - Adding / removing images

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        var newItems: [ImageItem] = []
        var skipped = 0

        func consider(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            guard ImageFiles.accepted.contains(ext) else { skipped += 1; return }
            if items.contains(where: { $0.url == url }) || newItems.contains(where: { $0.url == url }) { return }
            newItems.append(ImageItem(url: url, byteSize: fileSize(url)))
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

        notice = skipped > 0 ? "\(skipped) unsupported file\(skipped == 1 ? "" : "s") skipped." : nil
        guard !newItems.isEmpty else { return }

        for i in items.indices { items[i].status = .idle }
        items.append(contentsOf: newItems)
        if selectedID == nil { selectedID = items.first?.id }

        let ids = newItems.map { $0.id }
        Task {
            await loadFormatsIfNeeded()
            await loadMetadata(for: ids)
        }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        cropRects[id] = nil
        if selectedID == id {
            selectedID = items.first?.id
            refreshCropPreview()
        }
        if items.isEmpty { action = nil }
    }

    func clearAll() {
        guard !isRunning else { return }
        items = []
        selectedID = nil
        cropRects = [:]
        cropPreview = nil
        action = nil
        notice = nil
    }

    func select(_ id: UUID) {
        guard selectedID != id else { return }
        selectedID = id
        if action == .crop { refreshCropPreview() }
    }

    func choose(_ newAction: ImageAction) {
        action = newAction
        if newAction == .crop { refreshCropPreview() }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    func revealResults() {
        let outputs: [URL] = items.compactMap {
            if case .done(let output, _, _, _) = $0.status { return output }
            return nil
        }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Metadata, thumbnails, previews

    private func loadFormatsIfNeeded() async {
        guard writableFormats.isEmpty, let runner = app.runner else { return }
        if let listing = try? await runner.run(["-list", "format"]) {
            writableFormats = ImageFiles.writableFormats(from: listing)
        }
    }

    private func loadMetadata(for ids: [UUID]) async {
        for id in ids {
            guard let url = items.first(where: { $0.id == id })?.url else { continue }

            let box = await Task.detached(priority: .utility) {
                SendableBox(value: ImagePreview.cgImage(url: url, maxPixel: 240))
            }.value
            if let cg = box.value, let i = index(of: id) {
                items[i].thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }

            if let runner = app.runner, let size = await pixelSize(of: url, runner: runner), let i = index(of: id) {
                items[i].pixelSize = size
            }
        }
        if action == .crop { refreshCropPreview() }
    }

    /// Size after auto-orient, exactly as magick will see it when cropping.
    private func pixelSize(of url: URL, runner: MagickRunner) async -> CGSize? {
        do {
            let output = try await InputResolver.withPaths([url]) { paths in
                try await runner.run([firstFrame(paths[0]), "-auto-orient", "-format", "%w %h", "info:"])
            }
            let numbers = output
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .compactMap { Double($0) }
            if numbers.count >= 2, numbers[0] > 0, numbers[1] > 0 {
                return CGSize(width: numbers[0], height: numbers[1])
            }
        } catch {
            return nil
        }
        return nil
    }

    func refreshCropPreview() {
        guard let id = selectedID, let url = items.first(where: { $0.id == id })?.url else {
            cropPreview = nil
            return
        }
        cropPreview = nil
        Task {
            let box = await Task.detached(priority: .userInitiated) {
                SendableBox(value: ImagePreview.cgImage(url: url, maxPixel: 1800))
            }.value
            var image = box.value
            if image == nil, let runner = app.runner {
                image = await magickPreview(url: url, runner: runner)
            }
            if selectedID == id { cropPreview = image }
        }
    }

    /// Fallback when ImageIO can't decode a file: let magick render a PNG preview.
    private func magickPreview(url: URL, runner: MagickRunner) async -> CGImage? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await InputResolver.withPaths([url]) { paths in
                try await runner.run([firstFrame(paths[0]), "-auto-orient", "-resize", "1800x1800>", temp.path])
            }
        } catch {
            return nil
        }
        return ImagePreview.cgImage(url: temp, maxPixel: 1800)
    }

    // MARK: - Crop helpers

    /// Called after the aspect ratio changes: reshape the current crop to the new ratio.
    func applyRatioChange() {
        guard let item = selectedItem, let size = item.pixelSize,
              let ratio = cropSettings.ratio(imageSize: size) else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let base = cropRects[item.id] ?? bounds
        cropRects[item.id] = CropGeometry.fit(ratio: ratio, in: base, bounds: bounds)
    }

    /// Swap landscape/portrait: rotate the crop box around its center, then re-fit.
    func swapCropOrientation() {
        cropSettings.swapped.toggle()
        guard let item = selectedItem, let size = item.pixelSize else { return }
        let bounds = CGRect(origin: .zero, size: size)
        guard let current = cropRects[item.id] else { applyRatioChange(); return }

        var w = current.height
        var h = current.width
        let factor = min(1, bounds.width / w, bounds.height / h)
        w *= factor
        h *= factor
        var swapped = CGRect(x: current.midX - w / 2, y: current.midY - h / 2, width: w, height: h)
        swapped = CropGeometry.clampOrigin(swapped, in: bounds)

        if let ratio = cropSettings.ratio(imageSize: size) {
            swapped = CropGeometry.fit(ratio: ratio, in: swapped, bounds: bounds)
        }
        cropRects[item.id] = swapped
    }

    func resetCrop() {
        guard let id = selectedID else { return }
        cropRects[id] = nil
    }

    /// Copies the selected image's crop to every image, proportionally.
    func applyCropToAll() {
        guard let item = selectedItem, let size = item.pixelSize, let r = cropRects[item.id] else { return }
        let n = CGRect(x: r.minX / size.width, y: r.minY / size.height,
                       width: r.width / size.width, height: r.height / size.height)
        for other in items {
            guard let s = other.pixelSize else { continue }
            cropRects[other.id] = CGRect(x: n.minX * s.width, y: n.minY * s.height,
                                         width: n.width * s.width, height: n.height * s.height)
        }
    }

    // MARK: - Planning (everything except Compress)

    private struct Plan {
        let ext: String
        let suffix: String
        let note: String
        let arguments: (_ input: String, _ output: String) -> [String]
    }

    private func makePlan(action: ImageAction, item: ImageItem) throws -> Plan {
        let inExt = item.url.pathExtension.lowercased()
        let isHEIC = inExt == "heic" || inExt == "heif"
        // We never write HEIC from these actions (encoder support varies), so HEIC becomes JPG.
        let sameExt = isHEIC ? "jpg" : inExt
        let heicNote = isHEIC ? "saved as JPG" : ""

        switch action {
        case .compress:
            throw MagickError(message: "Compress uses the size search.")

        case .convert:
            let s = convert
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
            guard let size = item.pixelSize else {
                throw ItemSkip(message: "Image size isn't known yet. Try again in a moment.")
            }
            guard let r = cropRects[item.id] else {
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
            let s = resize
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
            let operation = rotate
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

    // MARK: - Running

    func run() async {
        guard let runner = app.runner, let action, !items.isEmpty, !isRunning else { return }
        isRunning = true
        reserved = []
        for i in items.indices { items[i].status = .idle }

        for index in items.indices {
            let item = items[index]
            items[index].status = .running(action == .compress ? "Finding the best fit…" : "Working…")
            do {
                if action == .compress {
                    items[index].status = try await processCompress(item, runner: runner)
                } else {
                    items[index].status = try await processSimple(item, action: action, runner: runner)
                }
            } catch let skip as ItemSkip {
                items[index].status = .skipped(skip.message)
            } catch {
                items[index].status = .failed(error.localizedDescription)
            }
        }
        isRunning = false
    }

    private func outputDirectory(for item: ImageItem) -> URL {
        outputFolder ?? item.url.deletingLastPathComponent()
    }

    private func processSimple(_ item: ImageItem, action: ImageAction, runner: MagickRunner) async throws -> ItemStatus {
        let plan = try makePlan(action: action, item: item)
        let stem = OutputNaming.sanitize(item.url.deletingPathExtension().lastPathComponent) + plan.suffix
        let output = OutputNaming.uniqueURL(directory: outputDirectory(for: item),
                                            stem: stem, ext: plan.ext, reserved: &reserved)

        _ = try await InputResolver.withPaths([item.url]) { paths in
            try await runner.run(plan.arguments(firstFrame(paths[0]), output.path))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MagickError(message: "magick finished but no output file was created.")
        }
        return .done(output: output, inBytes: item.byteSize, outBytes: fileSize(output), note: plan.note)
    }

    private func processCompress(_ item: ImageItem, runner: MagickRunner) async throws -> ItemStatus {
        let target = compress.targetBytes
        guard target > 0 else { throw MagickError(message: "Enter a target size above 0.") }

        let inExt = ImageFiles.normalizedExtension(item.url)
        let outExt: String
        switch compress.format {
        case .keep: outExt = ["jpg", "png", "webp"].contains(inExt) ? inExt : "jpg"
        case .jpg: outExt = "jpg"
        case .webp: outExt = "webp"
        }

        if outExt == inExt && item.byteSize <= target {
            throw ItemSkip(message: "Already \(formatBytes(item.byteSize)), under the target.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let strip = compress.stripMetadata
        let result = try await InputResolver.withPaths([item.url]) { paths in
            try await SizeCompressor(runner: runner).compress(
                inputPath: paths[0], ext: outExt, targetBytes: target, strip: strip, workDir: workDir)
        }

        let stem = OutputNaming.sanitize(item.url.deletingPathExtension().lastPathComponent) + ImageAction.compress.suffix
        let output = OutputNaming.uniqueURL(directory: outputDirectory(for: item),
                                            stem: stem, ext: outExt, reserved: &reserved)
        try FileManager.default.moveItem(at: result.file, to: output)

        var note = result.note
        if outExt != inExt { note += ", saved as \(outExt.uppercased())" }
        return .done(output: output, inBytes: item.byteSize, outBytes: result.bytes, note: note)
    }
}
