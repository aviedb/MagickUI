import Foundation

/// Watches ONE folder (top level only) and calls `onReady` once a new image has finished being written.
///
/// How it works: a kernel file-system event on the folder wakes us up, and a slow timer is a safety net.
/// On each scan we list the folder and compare against what we've seen. A new file must keep the same
/// size and modification time for about a second before it counts as finished, so half-written
/// downloads and screenshots are never touched.
@MainActor
final class FolderWatcher {
    private(set) var rule: WatchRule
    private let onReady: (WatchRule, URL) -> Void

    private struct Signature: Equatable {
        let size: Int64
        let modified: TimeInterval
    }

    private struct Pending {
        var signature: Signature
        var lastChange: Date
    }

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var known: [String: Signature] = [:]
    private var pending: [String: Pending] = [:]
    private var ignoredUntil: [String: Date] = [:]
    private var running = false
    private var scanGeneration = 0
    private let stableSeconds: TimeInterval = 1.0

    init(rule: WatchRule, onReady: @escaping (WatchRule, URL) -> Void) {
        self.rule = rule
        self.onReady = onReady
    }

    // MARK: Lifecycle

    func update(rule: WatchRule) {
        self.rule = rule
    }

    func start() {
        guard !running else { return }
        running = true
        // Images that are already in the folder are left alone.
        known = Dictionary(uniqueKeysWithValues: listFiles().map { ($0.url.path, $0.signature) })
        openSource()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        running = false
        scanGeneration += 1
        timer?.invalidate()
        timer = nil
        source?.cancel()
        source = nil
    }

    /// Call after the app writes a file into the folder, so it isn't mistaken for a new arrival.
    func noteWritten(_ url: URL) {
        ignoredUntil[url.path] = Date().addingTimeInterval(10)
    }

    /// Unprocessed images currently in a folder (used by "Process existing images now").
    static func existingImages(in folder: URL) -> [URL] {
        listImages(in: folder).map { $0.url }.filter { !ProcessedMarker.isMarked($0) }
    }

    // MARK: Events

    private func openSource() {
        guard source == nil else { return }
        let path = rule.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        newSource.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleEvent() }
        }
        newSource.setCancelHandler {
            close(fd)
        }
        newSource.resume()
        source = newSource
    }

    private func handleEvent() {
        if let data = source?.data, data.contains(.delete) || data.contains(.rename) {
            // The folder itself was moved or deleted. Drop the handle; the timer re-opens it if it returns.
            source?.cancel()
            source = nil
        }
        scheduleScan(after: 0.5)
    }

    private func scheduleScan(after delay: TimeInterval) {
        scanGeneration += 1
        let generation = scanGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.scanGeneration == generation else { return }
            self.scan()
        }
    }

    // MARK: Scanning

    private func scan() {
        guard running else { return }
        if source == nil { openSource() }

        let now = Date()
        let files = listFiles()
        var present = Set<String>()
        var needsFollowUp = false

        for (url, signature) in files {
            let path = url.path
            present.insert(path)

            if known[path] == signature { continue }
            if signature.size == 0 { needsFollowUp = true; continue }
            if let until = ignoredUntil[path], until > now { needsFollowUp = true; continue }
            if ProcessedMarker.isMarked(url) {
                known[path] = signature
                pending[path] = nil
                continue
            }

            if let existing = pending[path], existing.signature == signature {
                if now.timeIntervalSince(existing.lastChange) >= stableSeconds {
                    pending[path] = nil
                    known[path] = signature
                    onReady(rule, url)
                } else {
                    needsFollowUp = true
                }
            } else {
                pending[path] = Pending(signature: signature, lastChange: now)
                needsFollowUp = true
            }
        }

        pending = pending.filter { present.contains($0.key) }
        known = known.filter { present.contains($0.key) }
        ignoredUntil = ignoredUntil.filter { $0.value > now }

        if needsFollowUp { scheduleScan(after: 1.0) }
    }

    private func listFiles() -> [(url: URL, signature: Signature)] {
        Self.listImages(in: rule.folderURL)
    }

    private static func listImages(in folder: URL) -> [(url: URL, signature: Signature)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        var result: [(url: URL, signature: Signature)] = []
        for url in urls {
            guard ImageFiles.accepted.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let signature = Signature(
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            result.append((url, signature))
        }
        return result
    }
}
