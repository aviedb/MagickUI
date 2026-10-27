import Foundation
import AppKit
import Combine

/// State of the main window: the dropped images, the chosen action and its settings.
/// The actual image work lives in `ImageProcessor`.
@MainActor
final class Workspace: ObservableObject {
    let app: AppState

    @Published var items: [ImageItem] = []
    @Published var selectedID: UUID?
    @Published var action: ImageAction?

    @Published var optimize = OptimizeSettings()
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

    private var processorSettings: ProcessorSettings {
        var settings = ProcessorSettings()
        settings.optimize = optimize
        settings.compress = compress
        settings.convert = convert
        settings.resize = resize
        settings.rotate = rotate
        return settings
    }

    private func job(for item: ImageItem) -> ImageJob {
        ImageJob(url: item.url, byteSize: item.byteSize, pixelSize: item.pixelSize, cropRect: cropRects[item.id])
    }

    var commandPreview: String {
        guard let action, action != .compress, action != .optimize,
              let item = selectedItem ?? items.first,
              let plan = try? ImageProcessor.makePlan(action: action,
                                                      settings: processorSettings,
                                                      job: job(for: item),
                                                      writableFormats: writableFormats) else { return "" }
        let arguments = plan.arguments(firstFrame(item.url.path), "<output>")
        return (["magick"] + arguments).map(shellQuote).joined(separator: " ")
    }

    // MARK: - Adding / removing images

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let collected = ImageFiles.collect(from: urls)
        let newItems: [ImageItem] = collected.files
            .filter { url in !items.contains(where: { $0.url == url }) }
            .map { ImageItem(url: $0, byteSize: fileSize($0)) }

        notice = collected.skipped > 0
            ? "\(collected.skipped) unsupported file\(collected.skipped == 1 ? "" : "s") skipped."
            : nil
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

    // MARK: - Running

    func run() async {
        guard let runner = app.runner, let action, !items.isEmpty, !isRunning else { return }
        isRunning = true
        for i in items.indices { items[i].status = .idle }

        let processor = ImageProcessor(runner: runner, writableFormats: writableFormats)
        let settings = processorSettings
        var reserved = Set<String>()

        for index in items.indices {
            let item = items[index]
            items[index].status = .running(action == .compress ? "Finding the best fit…" : (action == .optimize ? "Optimizing…" : "Working…"))
            do {
                items[index].status = try await processor.process(job: job(for: item),
                                                                  action: action,
                                                                  settings: settings,
                                                                  outputDirectory: outputFolder,
                                                                  reserved: &reserved)
            } catch let skip as ItemSkip {
                items[index].status = .skipped(skip.message)
            } catch {
                items[index].status = .failed(error.localizedDescription)
            }
        }
        isRunning = false
    }
}
