import Foundation
import Combine

/// The video counterpart of `WatchManager`. It has its own folder list and its own queue, so a long video
/// encode never makes new images wait.
@MainActor
final class VideoWatchManager: ObservableObject {
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var totalSavedBytes: Int64 = 0
    @Published private(set) var activeFolderCount = 0
    @Published private(set) var isProcessing = false
    /// Mirrors the "Pause folder watching" switch (set by `AppContext`).
    @Published var isPaused = false {
        didSet { sync(rules: store.rules) }
    }

    private let store: VideoRuleStore
    private var watchers: [UUID: FolderWatcher] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var queue: [(rule: VideoWatchRule, url: URL)] = []
    private var isDraining = false
    private var encoders: Set<String> = []
    private var currentRunner: FFmpegRunner?
    private var readAttempts: [String: Int] = [:]

    /// Videos need longer to settle: a copy or a screen recording can pause for a moment between writes.
    private let stableSeconds: TimeInterval = 3

    init(store: VideoRuleStore) {
        self.store = store

        // `$rules` emits the NEW value, so use what it passes in, not store.rules.
        store.$rules
            .sink { [weak self] rules in
                guard let self else { return }
                Task { @MainActor in self.sync(rules: rules) }
            }
            .store(in: &cancellables)
    }

    // MARK: Syncing watchers with the saved rules

    private func sync(rules: [VideoWatchRule]) {
        var wanted: [UUID: VideoWatchRule] = [:]
        if !isPaused {
            for rule in rules where rule.enabled { wanted[rule.id] = rule }
        }

        for (id, watcher) in Array(watchers) {
            if let rule = wanted[id], rule.path == watcher.path { continue }
            watcher.stop()
            watchers[id] = nil
        }

        for (id, rule) in wanted where watchers[id] == nil {
            let watcher = FolderWatcher(path: rule.path,
                                        extensions: MediaFiles.videoExtensions,
                                        stableSeconds: stableSeconds) { [weak self] url in
                self?.fileReady(ruleID: id, url: url)
            }
            watchers[id] = watcher
            watcher.start()
        }
        activeFolderCount = watchers.count
    }

    private func fileReady(ruleID: UUID, url: URL) {
        guard let rule = store.rules.first(where: { $0.id == ruleID }) else { return }
        enqueue(rule, url)
    }

    /// "Process existing videos now" in Settings.
    func processExisting(in rule: VideoWatchRule) {
        for url in FolderWatcher.existingFiles(in: rule.folderURL, extensions: MediaFiles.videoExtensions) {
            enqueue(rule, url)
        }
    }

    /// Stops the video that is encoding right now. The next one in the queue still runs.
    func cancelCurrent() {
        currentRunner?.cancel()
    }

    // MARK: Queue

    private func enqueue(_ rule: VideoWatchRule, _ url: URL) {
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

    // MARK: Processing one video

    private func handle(rule: VideoWatchRule, url: URL) async {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path), !ProcessedMarker.isMarked(url) else { return }

        guard let ffmpeg = ExternalTool.ffmpeg, let ffprobe = ExternalTool.ffprobe else {
            let card = FloatingPreview.shared.begin(url: nil, name: name, title: rule.task.workingTitle)
            let message = "ffmpeg isn't installed. Run “brew install ffmpeg” in Terminal."
            log(name, message, success: false)
            FloatingPreview.shared.finish(card, .failed(message))
            return
        }

        // The card appears right away, with a thumbnail, and then fills its progress bar.
        let card = FloatingPreview.shared.begin(url: url, name: name, title: rule.task.workingTitle, isVideo: true)

        isProcessing = true
        defer { isProcessing = false }

        // A file can look finished before it is playable (for example a recording that is still being
        // closed). If it can't be read yet, try again a little later instead of failing.
        guard let info = await VideoProbe.probe(url: url, ffprobe: ffprobe) else {
            let attempts = (readAttempts[url.path] ?? 0) + 1
            if attempts < 4 {
                readAttempts[url.path] = attempts
                FloatingPreview.shared.dismiss(card)
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.enqueue(rule, url)
                }
            } else {
                readAttempts[url.path] = nil
                log(name, "Couldn't read this video.", success: false)
                FloatingPreview.shared.finish(card, .failed("Couldn't read this video."))
            }
            return
        }
        readAttempts[url.path] = nil

        if encoders.isEmpty,
           let result = try? await MagickRunner(executable: ffmpeg).execute(["-hide_banner", "-encoders"]),
           result.status == 0 {
            encoders = FFmpegCapabilities.encoders(from: result.stdout)
        }

        let runner = FFmpegRunner(executable: ffmpeg)
        currentRunner = runner
        defer { currentRunner = nil }
        let processor = VideoProcessor(ffmpeg: ffmpeg, runner: runner, magick: nil, encoders: encoders)

        var settings = VideoProcessorSettings()
        settings.optimize = rule.optimize
        settings.compress = rule.compress
        settings.downscale = rule.downscale
        settings.convert = rule.convert

        let action = rule.task.action
        let job = VideoJob(url: url, byteSize: fileSize(url), info: info)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-videowatch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            var reserved = Set<String>()
            let status = try await processor.process(
                job: job,
                action: action,
                settings: settings,
                outputDirectory: tempDir,
                reserved: &reserved,
                progress: { fraction in
                    Task { @MainActor in FloatingPreview.shared.setProgress(card, fraction) }
                })
            guard case .done(let output, let inBytes, let outBytes, let note) = status else {
                FloatingPreview.shared.finish(card, .unchanged("Nothing to do"))
                return
            }

            // Optimizing must never make a file bigger. Converting or downscaling is always kept.
            let sameFormat = output.pathExtension.lowercased() == url.pathExtension.lowercased()
            let shrinkingActions: [VideoAction] = [.optimize, .compress]
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
        } catch is VideoCancelled {
            log(name, "Cancelled.", success: true)
            FloatingPreview.shared.finish(card, .unchanged("Cancelled"))
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
