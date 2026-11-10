import AppKit
import Combine
import CoreML
import CryptoKit
import Foundation

// MARK: - Where the model lives

/// The model is not part of the app. It is installed under
/// `~/Library/Application Support/MagickUI/Models/withoutbg/`.
nonisolated enum BackgroundModelFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagickUI", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("withoutbg", isDirectory: true)
    }

    /// The compiled model that the engine loads.
    static var compiledModelURL: URL {
        root.appendingPathComponent("wbgnet_oss.mlmodelc", isDirectory: true)
    }

    /// The model is first prepared here, and only swapped in once it has been tested.
    static var incomingModelURL: URL {
        root.appendingPathComponent("incoming.mlmodelc", isDirectory: true)
    }

    static var recordURL: URL {
        root.appendingPathComponent("installed.json")
    }

    /// Licence and notice files that came with the model download.
    static var licensesURL: URL {
        root.appendingPathComponent("licenses", isDirectory: true)
    }

    /// Core ML's own cache for this app. macOS keeps prepared copies of the model here (it can grow to
    /// about 1 GB), and builds them again whenever they are missing, so clearing it is always safe.
    static var coreMLCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "MagickUI"
        return caches
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
    }
}

// MARK: - What to download

/// Describes the download. The same details are published in `models/manifest.json` in the repository,
/// so the file can move to another host without a new app version. If that file can't be fetched
/// (offline, not published yet), the built-in copy below is used. Either way the download is only
/// accepted if its SHA-256 matches.
nonisolated struct ModelManifest: Codable, Equatable {
    var id: String
    var version: String
    var url: URL
    var sha256: String
    var sizeBytes: Int64

    static let builtIn = ModelManifest(
        id: "withoutbg",
        version: "1",
        url: URL(string: "https://github.com/aviedb/MagickUI/releases/download/models-v1/wbgnet-v1.0-coreml.zip")!,
        sha256: "cec87249ab9eddc37147afc974c9cf005a1da7871cf6861ab6705e3ffe836370",
        sizeBytes: 353_134_784)

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/aviedb/MagickUI/main/models/manifest.json")!

    var isUsable: Bool {
        id == "withoutbg"
            && url.scheme == "https"
            && sha256.count == 64
            && sha256.allSatisfy { $0.isHexDigit }
            && sizeBytes > 0
    }

    /// The online manifest if there is a usable one, otherwise the built-in details.
    static func fetch() async -> ModelManifest {
        let request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              manifest.isUsable else {
            return builtIn
        }
        return manifest
    }
}

nonisolated struct InstalledModelRecord: Codable, Equatable {
    var id: String
    var version: String
    var sha256: String
    var installedAt: Date
    var diskBytes: Int64
}

// MARK: - Install progress and errors

nonisolated enum InstallPhase: Equatable {
    case checking, downloading, verifying, unpacking, preparing, testing

    var title: String {
        switch self {
        case .checking: return "Getting ready…"
        case .downloading: return "Downloading the model…"
        case .verifying: return "Checking the download…"
        case .unpacking: return "Unpacking…"
        case .preparing: return "Preparing the model for your Mac… (this can take a minute)"
        case .testing: return "Testing the model…"
        }
    }
}

nonisolated struct InstallStep: Equatable {
    var phase: InstallPhase
    /// 0...1 while downloading, nil for steps with no measurable progress.
    var fraction: Double?
}

nonisolated enum ModelInstallError: LocalizedError {
    case notEnoughSpace
    case badDownload(Int)
    case checksumMismatch
    case badArchive
    case wrongModel

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace:
            return "Not enough free disk space. The installation needs about 1.5 GB while it works, and the model takes about 0.5 GB afterwards."
        case .badDownload(let status):
            return status == 0
                ? "The download failed. Check your internet connection and try again."
                : "The download failed (server answered \(status)). Try again in a moment."
        case .checksumMismatch:
            return "The downloaded file is damaged (its checksum doesn't match). Please try again."
        case .badArchive:
            return "The downloaded file doesn't contain the model."
        case .wrongModel:
            return "The downloaded model isn't the one this app expects."
        }
    }
}

// MARK: - The store the UI watches

/// Downloads, installs and removes the optional Remove background model.
@MainActor
final class BackgroundModelStore: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var record: InstalledModelRecord?
    /// Non-nil while an install is running.
    @Published private(set) var step: InstallStep?
    @Published var errorMessage: String?
    /// Disk space used by Core ML's cache of prepared copies of the model.
    @Published private(set) var cacheBytes: Int64 = 0

    private var installTask: Task<Void, Never>?

    /// Free space the install needs at its peak (download + unpacked copy + compiled copy, with some room).
    private static let requiredFreeBytes: Int64 = 1_600_000_000

    var isBusy: Bool { step != nil }

    init() {
        refresh()
    }

    /// Looks at the disk again.
    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: BackgroundModelFiles.compiledModelURL.path)
        if isInstalled,
           let data = try? Data(contentsOf: BackgroundModelFiles.recordURL),
           let decoded = try? JSONDecoder().decode(InstalledModelRecord.self, from: data) {
            record = decoded
        } else {
            record = nil
        }
        refreshCacheSize()
    }

    /// Measures the cache again (off the main thread).
    func refreshCacheSize() {
        Task {
            let size = await Task.detached(priority: .utility) {
                ModelFileTools.folderSize(BackgroundModelFiles.coreMLCacheURL)
            }.value
            cacheBytes = size
        }
    }

    /// Deletes Core ML's cache. The model stays installed, and the next run is slower while the Mac prepares it again.
    func clearCache() {
        guard step == nil else { return }
        guard !BackgroundRemovalEngine.shared.isProcessing else {
            errorMessage = "An image is being processed. Clear the cache when it is finished."
            return
        }
        BackgroundRemovalEngine.shared.unload()
        do {
            if FileManager.default.fileExists(atPath: BackgroundModelFiles.coreMLCacheURL.path) {
                try FileManager.default.removeItem(at: BackgroundModelFiles.coreMLCacheURL)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't clear the cache: \(error.localizedDescription)"
        }
        refreshCacheSize()
    }

    /// Downloads and installs the model. Safe to call again to reinstall.
    func install() {
        guard installTask == nil else { return }
        errorMessage = nil
        installTask = Task { [weak self] in
            await self?.performInstall()
            self?.installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    /// Deletes the model and frees its disk space.
    func remove() {
        guard step == nil else { return }
        BackgroundRemovalEngine.shared.unload()
        try? FileManager.default.removeItem(at: BackgroundModelFiles.root)
        try? FileManager.default.removeItem(at: BackgroundModelFiles.coreMLCacheURL)
        errorMessage = nil
        refresh()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([BackgroundModelFiles.root])
    }

    /// Opens the licence and notice files that came with the model, if there are any.
    func openLicenses() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: BackgroundModelFiles.licensesURL, includingPropertiesForKeys: nil)) ?? []
        if let first = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            NSWorkspace.shared.open(first)
        }
    }

    fileprivate func updateDownload(_ fraction: Double) {
        guard let current = step, current.phase == .downloading else { return }
        step = InstallStep(phase: .downloading, fraction: min(max(fraction, 0), 1))
    }

    // MARK: The install itself

    private func performInstall() async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("MagickTools-model-\(UUID().uuidString)", isDirectory: true)
        let incoming = BackgroundModelFiles.incomingModelURL
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: incoming)
        }

        do {
            step = InstallStep(phase: .checking, fraction: nil)
            let manifest = await ModelManifest.fetch()
            try Task.checkCancellation()
            try Self.ensureFreeSpace()

            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.createDirectory(at: BackgroundModelFiles.root, withIntermediateDirectories: true)

            // 1. Download.
            step = InstallStep(phase: .downloading, fraction: 0)
            let zip = try await ModelDownload.fetch(manifest.url, into: work) { [weak self] value in
                Task { @MainActor in self?.updateDownload(value) }
            }
            try Task.checkCancellation()

            // 2. Make sure it is exactly the file that was published.
            step = InstallStep(phase: .verifying, fraction: nil)
            let digest = try await Task.detached(priority: .utility) {
                try ModelFileTools.sha256(of: zip)
            }.value
            guard digest == manifest.sha256.lowercased() else { throw ModelInstallError.checksumMismatch }
            try Task.checkCancellation()

            // 3. Unpack.
            step = InstallStep(phase: .unpacking, fraction: nil)
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await MagickRunner(executable: URL(fileURLWithPath: "/usr/bin/ditto"))
                .run(["-x", "-k", zip.path, unpacked.path])
            try? fm.removeItem(at: zip)          // free the space right away

            guard let package = ModelFileTools.findPackage(in: unpacked) else { throw ModelInstallError.badArchive }
            let sourceFolder = package.deletingLastPathComponent()
            let extras = ((try? fm.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension != "mlpackage" && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            try Task.checkCancellation()

            // 4. Compile it for this Mac (Core ML does this on the device).
            step = InstallStep(phase: .preparing, fraction: nil)
            let compiled = try await MLModel.compileModel(at: package)
            try? fm.removeItem(at: incoming)
            try fm.moveItem(at: compiled, to: incoming)
            try? fm.removeItem(at: package)      // free the space right away

            // 5. Test it before it replaces anything.
            step = InstallStep(phase: .testing, fraction: nil)
            try await Task.detached(priority: .utility) {
                try ModelFileTools.validate(modelAt: incoming)
            }.value

            // 6. Swap it in.
            BackgroundRemovalEngine.shared.unload()
            let final = BackgroundModelFiles.compiledModelURL
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: incoming)
            } else {
                try fm.moveItem(at: incoming, to: final)
            }

            // 7. Keep the licence and notice files next to the model.
            let licenses = BackgroundModelFiles.licensesURL
            try? fm.removeItem(at: licenses)
            try? fm.createDirectory(at: licenses, withIntermediateDirectories: true)
            for file in extras {
                // Files with no extension (such as THIRD_PARTY_NOTICES) get ".txt", so they open in a text editor.
                let name = file.pathExtension.isEmpty ? file.lastPathComponent + ".txt" : file.lastPathComponent
                try? fm.copyItem(at: file, to: licenses.appendingPathComponent(name))
            }

            // 8. Remember what is installed.
            let size = await Task.detached(priority: .utility) {
                ModelFileTools.folderSize(final)
            }.value
            let newRecord = InstalledModelRecord(id: manifest.id,
                                                 version: manifest.version,
                                                 sha256: manifest.sha256.lowercased(),
                                                 installedAt: Date(),
                                                 diskBytes: size)
            if let data = try? JSONEncoder().encode(newRecord) {
                try? data.write(to: BackgroundModelFiles.recordURL, options: .atomic)
            }

            step = nil
            errorMessage = nil
            refresh()
            BackgroundRemovalEngine.shared.preload()
        } catch is CancellationError {
            step = nil
            refresh()
        } catch let error as URLError where error.code == .cancelled {
            step = nil
            refresh()
        } catch {
            step = nil
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    private static func ensureFreeSpace() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if available < requiredFreeBytes { throw ModelInstallError.notEnoughSpace }
    }
}

// MARK: - Download

nonisolated enum ModelDownload {
    /// Downloads `url` into `directory` and reports 0...1 progress. Cancelling the calling task cancels the download.
    static func fetch(_ url: URL,
                      into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let observer = ProgressObserver(progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelInstallError.badDownload((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let destination = directory.appendingPathComponent("model.zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Watches the download task's progress and passes it on (not more often than every half percent).
    private final class ProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?
        private var lastReported = -1.0

        init(_ onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                guard let self else { return }
                let value = progress.fractionCompleted
                guard value - self.lastReported >= 0.005 || value >= 1 else { return }
                self.lastReported = value
                self.onProgress(value)
            }
        }
    }
}

// MARK: - File helpers (all synchronous, called off the main thread)

nonisolated enum ModelFileTools {
    /// SHA-256 of a file, read in chunks so a large file never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first `.mlpackage` inside the unpacked download (at the top, or one folder down).
    static func findPackage(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let item = enumerator.nextObject() as? URL {
            if item.pathExtension == "mlpackage" { return item }
        }
        return nil
    }

    /// Loads the compiled model once and checks that it has the input and output the engine uses.
    static func validate(modelAt url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let description = model.modelDescription
        guard description.inputDescriptionsByName[BackgroundRemovalEngine.inputName] != nil,
              description.outputDescriptionsByName[BackgroundRemovalEngine.outputName] != nil else {
            throw ModelInstallError.wrongModel
        }
    }

    /// Disk space used by a folder.
    static func folderSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
