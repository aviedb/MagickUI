import Foundation
import AppKit
import Combine

/// State of the main window: the dropped files (images and videos), the chosen action and its settings.
/// The actual work lives in `ImageProcessor` and `VideoProcessor`.
@MainActor
final class Workspace: ObservableObject {
    let app: AppState

    @Published var items: [ImageItem] = []
    @Published var selectedID: UUID?
    /// Which kind of file the actions apply to. Dropping both kinds shows a switch.
    @Published var activeKind: MediaKind = .image

    // Image actions
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

    // Video actions
    @Published var videoAction: VideoAction?
    @Published var videoOptimize = VideoOptimizeSettings()
    @Published var videoCompress = VideoCompressSettings()
    @Published var videoDownscale = VideoDownscaleSettings()
    @Published var videoConvert = VideoConvertSettings()
    @Published var videoTrim = VideoTrimSettings()
    @Published var frameSettings = FrameSettings()
    @Published var frameFormat = ConvertSettings(target: "png", useOther: false, otherExtension: "", quality: 90)
    /// The part to keep, per video. A video with no entry is untouched.
    @Published var trimRanges: [UUID: TimeRange] = [:]
    @Published var frameTimes: [UUID: Double] = [:]

    @Published var outputFolder: URL?
    @Published var isRunning = false
    @Published var notice: String?
    @Published private(set) var writableFormats: Set<String> = []
    @Published private(set) var ffmpegEncoders: Set<String> = []

    private var ffmpegRunner: FFmpegRunner?

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

    var hasImages: Bool { items.contains { $0.kind == .image } }
    var hasVideos: Bool { items.contains { $0.kind == .video } }
    var hasBothKinds: Bool { hasImages && hasVideos }
    var imageCount: Int { items.filter { $0.kind == .image }.count }
    var videoCount: Int { items.filter { $0.kind == .video }.count }

    /// "3 images", "2 videos" or "3 images · 2 videos".
    var countText: String {
        var parts: [String] = []
        if imageCount > 0 { parts.append(imageCount == 1 ? "1 image" : "\(imageCount) images") }
        if videoCount > 0 { parts.append(videoCount == 1 ? "1 video" : "\(videoCount) videos") }
        return parts.joined(separator: " · ")
    }

    var ffmpegAvailable: Bool { ExternalTool.ffmpeg != nil }

    /// Formats offered as one-tap choices in Convert (filtered to what magick can actually write).
    var convertChoices: [String] {
        let curated = ["jpg", "png", "webp", "heic", "avif", "tiff", "gif", "bmp", "ico", "jp2", "jxl"]
        guard !writableFormats.isEmpty else { return curated }
        return curated.filter { writableFormats.contains($0.uppercased()) }
    }

    var canWriteWebP: Bool {
        writableFormats.isEmpty || writableFormats.contains("WEBP")
    }

    /// Video Convert targets this ffmpeg can actually produce.
    var availableVideoFormats: [VideoFormat] {
        guard !ffmpegEncoders.isEmpty else { return VideoFormat.allCases }
        return VideoFormat.allCases.filter { format in
            format.requiredEncoders.allSatisfy { ffmpegEncoders.contains($0) }
        }
    }

    // MARK: Run bar helpers

    var hasAction: Bool {
        activeKind == .image ? action != nil : videoAction != nil
    }

    var runVerb: String {
        activeKind == .image ? (action?.verb ?? "Run") : (videoAction?.verb ?? "Run")
    }

    /// "image(s)" or "video(s)" for the Run button.
    var runNounSingular: String { activeKind == .image ? "image" : "video" }
    var runNounPlural: String { activeKind == .image ? "images" : "videos" }

    /// The command-line tool the current mode needs is available.
    var toolsReady: Bool {
        activeKind == .image ? app.runner != nil : ffmpegAvailable
    }

    func isTrimModified(_ item: ImageItem) -> Bool {
        guard let range = trimRanges[item.id], let duration = item.video?.duration else { return false }
        return range.start > 0.01 || range.end < duration - 0.01
    }

    /// How many files the current action would touch.
    var runCount: Int {
        if activeKind == .video {
            if videoAction == .trim { return items.filter { $0.kind == .video && isTrimModified($0) }.count }
            return videoCount
        }
        if action == .crop { return items.filter { $0.kind == .image && cropRects[$0.id] != nil }.count }
        return imageCount
    }

    var hasResults: Bool {
        items.contains { item in
            guard item.kind == activeKind else { return false }
            if case .done = item.status { return true }
            return false
        }
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
        guard activeKind == .image,
              let action, action != .compress, action != .optimize,
              let item = (selectedItem?.kind == .image ? selectedItem : nil) ?? items.first(where: { $0.kind == .image }),
              let plan = try? ImageProcessor.makePlan(action: action,
                                                      settings: processorSettings,
                                                      job: job(for: item),
                                                      writableFormats: writableFormats) else { return "" }
        let arguments = plan.arguments(firstFrame(item.url.path), "<output>")
        return (["magick"] + arguments).map(shellQuote).joined(separator: " ")
    }

    // MARK: - Adding / removing files

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let collected = MediaFiles.collect(from: urls)
        let existing = Set(items.map { $0.url })

        var newItems: [ImageItem] = []
        for url in collected.images where !existing.contains(url) {
            newItems.append(ImageItem(url: url, byteSize: fileSize(url), kind: .image))
        }
        for url in collected.videos where !existing.contains(url) {
            newItems.append(ImageItem(url: url, byteSize: fileSize(url), kind: .video))
        }

        notice = collected.skipped > 0
            ? "\(collected.skipped) unsupported file\(collected.skipped == 1 ? "" : "s") skipped."
            : nil
        guard !newItems.isEmpty else { return }

        for i in items.indices { items[i].status = .idle }
        items.append(contentsOf: newItems)

        // Show the actions for what was just dropped. If both kinds arrive together, images come first.
        let newKinds = Set(newItems.map { $0.kind })
        if newKinds.count == 1, let kind = newKinds.first {
            activeKind = kind
        } else if !items.contains(where: { $0.kind == activeKind }) {
            activeKind = items.first?.kind ?? .image
        }
        if selectedItem == nil || selectedItem?.kind != activeKind {
            selectedID = newItems.first(where: { $0.kind == activeKind })?.id ?? items.first?.id
        }

        let ids = newItems.map { $0.id }
        Task {
            await loadFormatsIfNeeded()
            await loadEncodersIfNeeded()
            await loadMetadata(for: ids)
        }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        cropRects[id] = nil
        trimRanges[id] = nil
        frameTimes[id] = nil
        if selectedID == id {
            selectedID = items.first(where: { $0.kind == activeKind })?.id ?? items.first?.id
            refreshCropPreview()
        }
        if !items.contains(where: { $0.kind == activeKind }), let first = items.first {
            activeKind = first.kind
        }
        if items.isEmpty {
            action = nil
            videoAction = nil
        }
    }

    func clearAll() {
        guard !isRunning else { return }
        items = []
        selectedID = nil
        cropRects = [:]
        trimRanges = [:]
        frameTimes = [:]
        cropPreview = nil
        action = nil
        videoAction = nil
        notice = nil
    }

    func select(_ id: UUID) {
        guard selectedID != id else { return }
        selectedID = id
        if let item = items.first(where: { $0.id == id }), item.kind != activeKind {
            activeKind = item.kind
        }
        if action == .crop { refreshCropPreview() }
    }

    func setKind(_ kind: MediaKind) {
        guard kind != activeKind else { return }
        activeKind = kind
        if selectedItem?.kind != kind {
            selectedID = items.first(where: { $0.kind == kind })?.id
        }
        if kind == .image, action == .crop { refreshCropPreview() }
    }

    func choose(_ newAction: ImageAction) {
        action = newAction
        if newAction == .crop { refreshCropPreview() }
    }

    func chooseVideo(_ newAction: VideoAction) {
        videoAction = newAction
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
            guard $0.kind == activeKind else { return nil }
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

    private func loadEncodersIfNeeded() async {
        guard hasVideos, ffmpegEncoders.isEmpty, let ffmpeg = ExternalTool.ffmpeg else { return }
        if let result = try? await MagickRunner(executable: ffmpeg).execute(["-hide_banner", "-encoders"]),
           result.status == 0 {
            ffmpegEncoders = FFmpegCapabilities.encoders(from: result.stdout)
        }
    }

    private func loadMetadata(for ids: [UUID]) async {
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if item.kind == .video {
                await loadVideoMetadata(id: id, url: item.url)
                continue
            }
            let url = item.url

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

    private func loadVideoMetadata(id: UUID, url: URL) async {
        var info: VideoInfo?
        if let ffprobe = ExternalTool.ffprobe {
            info = await VideoProbe.probe(url: url, ffprobe: ffprobe)
            if let info, let i = index(of: id) {
                items[i].video = info
                items[i].pixelSize = CGSize(width: info.width, height: info.height)
            }
        }
        if let ffmpeg = ExternalTool.ffmpeg {
            // A frame a little way in is usually more telling than the very first (often black) one.
            let moment = min(1.0, (info?.duration ?? 2) * 0.1)
            if let cg = await FrameGrabber.frame(url: url, at: moment, maxWidth: 240, ffmpeg: ffmpeg),
               let i = index(of: id) {
                items[i].thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
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
        guard let id = selectedID, let item = items.first(where: { $0.id == id }), item.kind == .image else {
            cropPreview = nil
            return
        }
        let url = item.url
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
        for other in items where other.kind == .image {
            guard let s = other.pixelSize else { continue }
            cropRects[other.id] = CGRect(x: n.minX * s.width, y: n.minY * s.height,
                                         width: n.width * s.width, height: n.height * s.height)
        }
    }

    // MARK: - Video helpers

    func trimRange(for item: ImageItem) -> TimeRange {
        let duration = item.video?.duration ?? 0
        return trimRanges[item.id] ?? TimeRange(start: 0, end: duration)
    }

    func setTrim(_ range: TimeRange, for id: UUID) {
        trimRanges[id] = range
    }

    func resetTrim(for id: UUID) {
        trimRanges[id] = nil
    }

    /// Copies the selected video's start and end to every video (clamped to each one's length).
    func applyTrimToAll() {
        guard let item = selectedItem, item.kind == .video else { return }
        let range = trimRange(for: item)
        for other in items where other.kind == .video {
            guard let duration = other.video?.duration, range.start < duration - 0.1 else { continue }
            trimRanges[other.id] = TimeRange(start: range.start, end: min(range.end, duration))
        }
    }

    func frameTime(for item: ImageItem) -> Double {
        frameTimes[item.id] ?? min(1, (item.video?.duration ?? 0) * 0.1)
    }

    func setFrameTime(_ time: Double, for item: ImageItem) {
        let duration = item.video?.duration ?? 0
        frameTimes[item.id] = min(max(0, time), max(0, duration - 0.05))
    }

    /// After installing ffmpeg: look for the tools again and read any videos that couldn't be read before.
    func refreshVideoTools() {
        objectWillChange.send()
        Task {
            await loadEncodersIfNeeded()
            let unread = items.filter { $0.kind == .video && $0.video == nil }.map { $0.id }
            await loadMetadata(for: unread)
        }
    }

    // MARK: - Running

    func run() async {
        if activeKind == .video {
            await runVideos()
        } else {
            await runImages()
        }
    }

    /// Stops the video that is encoding right now and the rest of the batch.
    func cancel() {
        ffmpegRunner?.cancel()
    }

    private func runImages() async {
        guard let runner = app.runner, let action, !isRunning else { return }
        let indices = items.indices.filter { items[$0].kind == .image }
        guard !indices.isEmpty else { return }

        isRunning = true
        for i in indices { items[i].status = .idle }

        let processor = ImageProcessor(runner: runner, writableFormats: writableFormats)
        let settings = processorSettings
        var reserved = Set<String>()

        for index in indices {
            let item = items[index]
            items[index].status = .running(action == .compress ? "Finding the best fit…"
                                           : (action == .optimize ? "Optimizing…" : "Working…"))
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

    private func runVideos() async {
        guard let videoAction, let ffmpeg = ExternalTool.ffmpeg, !isRunning else { return }
        let indices = items.indices.filter { items[$0].kind == .video }
        guard !indices.isEmpty else { return }

        isRunning = true
        for i in indices {
            items[i].status = .idle
            items[i].progress = nil
        }
        await loadEncodersIfNeeded()

        let runner = FFmpegRunner(executable: ffmpeg)
        ffmpegRunner = runner
        let processor = VideoProcessor(ffmpeg: ffmpeg, runner: runner, magick: app.runner,
                                       encoders: ffmpegEncoders, writableFormats: writableFormats)

        var settings = VideoProcessorSettings()
        settings.optimize = videoOptimize
        settings.compress = videoCompress
        settings.downscale = videoDownscale
        settings.convert = videoConvert
        settings.trim = videoTrim
        settings.frame = frameSettings
        settings.frameFormat = frameFormat

        var reserved = Set<String>()
        var cancelled = false

        for index in indices {
            if cancelled { break }
            let item = items[index]

            if videoAction == .trim && !isTrimModified(item) {
                items[index].status = .skipped("No trim range set for this video.")
                continue
            }

            let id = item.id
            items[index].status = .running("Starting…")
            items[index].progress = 0

            let job = VideoJob(url: item.url,
                               byteSize: item.byteSize,
                               info: item.video,
                               trim: trimRanges[id],
                               frameTime: frameTime(for: item))
            do {
                let status = try await processor.process(
                    job: job,
                    action: videoAction,
                    settings: settings,
                    outputDirectory: outputFolder,
                    reserved: &reserved,
                    progress: { fraction in
                        Task { @MainActor [weak self] in self?.setProgress(fraction, for: id) }
                    })
                items[index].status = status
            } catch let skip as ItemSkip {
                items[index].status = .skipped(skip.message)
            } catch is VideoCancelled {
                items[index].status = .skipped("Cancelled")
                cancelled = true
            } catch {
                items[index].status = .failed(error.localizedDescription)
            }
            items[index].progress = nil
        }

        ffmpegRunner = nil
        isRunning = false
    }

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let i = index(of: id), case .running = items[i].status else { return }
        items[i].progress = fraction
        items[i].status = .running("Encoding \(Int((fraction * 100).rounded()))%")
    }
}
