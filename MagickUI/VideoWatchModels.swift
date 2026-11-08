import Foundation
import Combine

// MARK: - What a watched video folder does

nonisolated enum VideoWatchTask: String, CaseIterable, Identifiable, Codable {
    case optimize, compress, downscale, convert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to an exact target size"
        case .downscale: return "Downscale"
        case .convert: return "Convert to another format"
        }
    }

    var shortTitle: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to size"
        case .downscale: return "Downscale"
        case .convert: return "Convert"
        }
    }

    /// What the floating preview says while this runs.
    var workingTitle: String {
        switch self {
        case .optimize: return "Optimizing…"
        case .compress: return "Compressing…"
        case .downscale: return "Downscaling…"
        case .convert: return "Converting…"
        }
    }

    var action: VideoAction {
        switch self {
        case .optimize: return .optimize
        case .compress: return .compress
        case .downscale: return .downscale
        case .convert: return .convert
        }
    }
}

nonisolated struct VideoWatchRule: Codable, Identifiable {
    var id = UUID()
    var path: String
    var enabled = true
    var task: VideoWatchTask = .optimize
    var optimize = VideoOptimizeSettings()
    var compress = VideoCompressSettings()
    var downscale = VideoDownscaleSettings()
    var convert = VideoConvertSettings()
    var originalHandling: OriginalHandling = .trash
    var onlyIfSmaller = true

    var folderURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var folderName: String { folderURL.lastPathComponent.isEmpty ? path : folderURL.lastPathComponent }

    init(path: String) {
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, enabled, task, optimize, compress, downscale, convert, originalHandling, onlyIfSmaller
    }

    /// Rules saved by an older version are missing newer keys, so every key falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        task = try container.decodeIfPresent(VideoWatchTask.self, forKey: .task) ?? .optimize
        optimize = try container.decodeIfPresent(VideoOptimizeSettings.self, forKey: .optimize) ?? optimize
        compress = try container.decodeIfPresent(VideoCompressSettings.self, forKey: .compress) ?? compress
        downscale = try container.decodeIfPresent(VideoDownscaleSettings.self, forKey: .downscale) ?? downscale
        convert = try container.decodeIfPresent(VideoConvertSettings.self, forKey: .convert) ?? convert
        originalHandling = try container.decodeIfPresent(OriginalHandling.self, forKey: .originalHandling) ?? .trash
        onlyIfSmaller = try container.decodeIfPresent(Bool.self, forKey: .onlyIfSmaller) ?? true
    }
}

// MARK: - Saved list (separate from the image folders)

@MainActor
final class VideoRuleStore: ObservableObject {
    @Published var rules: [VideoWatchRule] {
        didSet { save() }
    }

    private let key = "videoWatchRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: "videoWatchRules"),
           let decoded = try? JSONDecoder().decode([VideoWatchRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Adds a rule for the folder (unless it's already watched) and returns its id.
    @discardableResult
    func addFolder(_ url: URL) -> UUID {
        if let existing = rules.first(where: { $0.path == url.path }) { return existing.id }
        let rule = VideoWatchRule(path: url.path)
        rules.append(rule)
        return rule.id
    }
}
