import Foundation
import Combine

/// Starts and stops a `FolderWatcher` per enabled rule, and processes new images one at a time.
@MainActor
final class WatchManager: ObservableObject {
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var totalSavedBytes: Int64 = 0
    @Published private(set) var activeFolderCount = 0
    @Published private(set) var isProcessing = false
    @Published var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "watchPaused")
            sync(rules: store.rules)
        }
    }

    private let app: AppState
    private let store: RuleStore
    private let settings: AppSettings

    private var watchers: [UUID: FolderWatcher] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var queue: [(rule: WatchRule, url: URL)] = []
    private var isDraining = false
    private var formats: Set<String> = []

    init(app: AppState, store: RuleStore, settings: AppSettings) {
        self.app = app
        self.store = store
        self.settings = settings
        self.isPaused = UserDefaults.standard.bool(forKey: "watchPaused")

        // `$rules` emits the NEW value, so use what it passes in, not store.rules.
        store.$rules
            .sink { [weak self] rules in
                guard let self else { return }
                Task { @MainActor in self.sync(rules: rules) }
            }
            .store(in: &cancellables)
    }

    // MARK: Syncing watchers with the saved rules

    private func sync(rules: [WatchRule]) {
        var wanted: [UUID: WatchRule] = [:]
        if !isPaused {
            for rule in rules where rule.enabled { wanted[rule.id] = rule }
        }

        for (id, watcher) in Array(watchers) {
            if let rule = wanted[id], rule.path == watcher.rule.path {
                watcher.update(rule: rule)
            } else {
                watcher.stop()
                watchers[id] = nil
            }
        }

        for (id, rule) in wanted where watchers[id] == nil {
            let watcher = FolderWatcher(rule: rule) { [weak self] rule, url in
                self?.enqueue(rule, url)
            }
            watchers[id] = watcher
            watcher.start()
        }
        activeFolderCount = watchers.count
    }

    /// "Process existing images now" in Settings.
    func processExisting(in rule: WatchRule) {
        for url in FolderWatcher.existingImages(in: rule.folderURL) {
            enqueue(rule, url)
        }
    }

    // MARK: Queue

    private func enqueue(_ rule: WatchRule, _ url: URL) {
        queue.append((rule, url))
        if !isDraining {
            Task { await drain() }
        }
    }

    private func drain() async {
        isDraining = true
        defer { isDraining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await handle(rule: next.rule, url: next.url)
        }
    }

    // MARK: Processing one image

    private func handle(rule: WatchRule, url: URL) async {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path), !ProcessedMarker.isMarked(url) else { return }

        // The floating card appears right away, then turns into the result.
        let card = FloatingPreview.shared.begin(url: url, name: name)

        guard let runner = app.runner else {
            log(name, "ImageMagick isn't available.", success: false)
            FloatingPreview.shared.finish(card, .failed("ImageMagick isn't available."))
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        if formats.isEmpty, let listing = try? await runner.run(["-list", "format"]) {
            formats = ImageFiles.writableFormats(from: listing)
        }

        let action = rule.task.action
        var processorSettings = ProcessorSettings()
        processorSettings.optimize = rule.optimize
        processorSettings.compress = rule.compress
        processorSettings.convert = rule.convert
        processorSettings.resize = rule.resize

        let processor = ImageProcessor(runner: runner, writableFormats: formats)
        let job = ImageJob(url: url, byteSize: fileSize(url))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-watch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            var reserved = Set<String>()
            let status = try await processor.process(job: job,
                                                     action: action,
                                                     settings: processorSettings,
                                                     outputDirectory: tempDir,
                                                     reserved: &reserved)
            guard case .done(let output, let inBytes, let outBytes, let note) = status else {
                FloatingPreview.shared.finish(card, .unchanged("Nothing to do"))
                return
            }

            // Optimizing must never make a file bigger. Converting to another format is the exception:
            // that result is kept even if it's larger (for example HEIC to JPG).
            let sameFormat = output.pathExtension.lowercased() == url.pathExtension.lowercased()
            let shrinkingActions: [ImageAction] = [.optimize, .compress, .metadata]
            let onlyIfSmaller = rule.onlyIfSmaller && sameFormat && shrinkingActions.contains(action)
            if onlyIfSmaller && outBytes >= inBytes {
                log(name, "Already as small as it can get.", success: true)
                FloatingPreview.shared.finish(card, .unchanged("Already as small as it gets"))
                return
            }

            let finalURL = try InPlaceFinalizer.finalize(original: url,
                                                         processed: output,
                                                         handling: rule.originalHandling)
            watchers[rule.id]?.noteWritten(finalURL)

            let saved = inBytes - outBytes
            if saved > 0 { totalSavedBytes += saved }

            var message = "\(formatBytes(inBytes)) → \(formatBytes(outBytes))"
            if !note.isEmpty { message += " (\(note))" }
            log(name, message, success: true)
            FloatingPreview.shared.finish(card, .saved(inBytes: inBytes, outBytes: outBytes,
                                                       detail: note, reveal: finalURL))
        } catch let skip as ItemSkip {
            log(name, skip.message, success: true)
            FloatingPreview.shared.finish(card, .unchanged(skip.message))
        } catch {
            log(name, error.localizedDescription, success: false)
            FloatingPreview.shared.finish(card, .failed(error.localizedDescription))
        }
    }

    private func log(_ name: String, _ message: String, success: Bool) {
        activity.insert(ActivityEntry(name: name, message: message, success: success), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
