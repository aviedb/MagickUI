import Foundation
import Combine

// MARK: - Rules

/// What a watched folder does to each new image.
nonisolated enum WatchTask: String, CaseIterable, Identifiable, Codable {
    case optimize, compress, convert, resize, metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to an exact target size"
        case .convert: return "Convert to another format"
        case .resize: return "Shrink to a maximum size"
        case .metadata: return "Remove metadata"
        }
    }

    var shortTitle: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to size"
        case .convert: return "Convert"
        case .resize: return "Resize"
        case .metadata: return "Remove metadata"
        }
    }

    var action: ImageAction {
        switch self {
        case .optimize: return .optimize
        case .compress: return .compress
        case .convert: return .convert
        case .resize: return .resize
        case .metadata: return .metadata
        }
    }
}

nonisolated struct WatchRule: Codable, Identifiable {
    var id = UUID()
    var path: String
    var enabled = true
    var task: WatchTask = .optimize
    var optimize = OptimizeSettings()
    var compress = CompressSettings(amount: 500, unit: .kb, format: .keep, stripMetadata: true)
    var convert = ConvertSettings()
    var resize = ResizeSettings(mode: .pixels, width: 2000, height: 0, percent: 50, keepAspect: true, shrinkOnly: true)
    var originalHandling: OriginalHandling = .trash
    var onlyIfSmaller = true

    var folderURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var folderName: String { folderURL.lastPathComponent.isEmpty ? path : folderURL.lastPathComponent }

    init(path: String) {
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, enabled, task, optimize, compress, convert, resize, originalHandling, onlyIfSmaller
    }

    /// Rules saved by an older version are missing newer keys, so every key falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        task = try container.decodeIfPresent(WatchTask.self, forKey: .task) ?? .optimize
        optimize = try container.decodeIfPresent(OptimizeSettings.self, forKey: .optimize) ?? OptimizeSettings()
        compress = try container.decodeIfPresent(CompressSettings.self, forKey: .compress) ?? compress
        convert = try container.decodeIfPresent(ConvertSettings.self, forKey: .convert) ?? convert
        resize = try container.decodeIfPresent(ResizeSettings.self, forKey: .resize) ?? resize
        originalHandling = try container.decodeIfPresent(OriginalHandling.self, forKey: .originalHandling) ?? .trash
        onlyIfSmaller = try container.decodeIfPresent(Bool.self, forKey: .onlyIfSmaller) ?? true
    }
}

// MARK: - Dock icon behavior

nonisolated enum DockMode: String, CaseIterable, Identifiable {
    case whileOpen = "Only while a window is open"
    case always = "Always"
    case never = "Never (menu bar only)"

    var id: String { rawValue }
}

// MARK: - Stores

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [WatchRule] {
        didSet { save() }
    }

    private let key = "watchRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: "watchRules"),
           let decoded = try? JSONDecoder().decode([WatchRule].self, from: data) {
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
        let rule = WatchRule(path: url.path)
        rules.append(rule)
        return rule.id
    }
}

@MainActor
final class AppSettings: ObservableObject {
    /// The small floating preview in the bottom-right corner.
    @Published var showFloatingPreview: Bool {
        didSet { UserDefaults.standard.set(showFloatingPreview, forKey: "showFloatingPreview") }
    }
    @Published var showWindowAtLaunch: Bool {
        didSet { UserDefaults.standard.set(showWindowAtLaunch, forKey: "showWindowAtLaunch") }
    }
    @Published var dockMode: DockMode {
        didSet { UserDefaults.standard.set(dockMode.rawValue, forKey: "dockMode") }
    }
    /// Strength of the silent "Quick compress" Finder service (Balanced or Aggressive).
    @Published var quickLevel: OptimizeLevel {
        didSet { UserDefaults.standard.set(quickLevel.rawValue, forKey: "quickLevel") }
    }

    init() {
        let defaults = UserDefaults.standard
        showFloatingPreview = defaults.object(forKey: "showFloatingPreview") as? Bool ?? true
        showWindowAtLaunch = defaults.object(forKey: "showWindowAtLaunch") as? Bool ?? true
        dockMode = DockMode(rawValue: defaults.string(forKey: "dockMode") ?? "") ?? .whileOpen
        let saved = OptimizeLevel(rawValue: defaults.string(forKey: "quickLevel") ?? "") ?? .balanced
        quickLevel = saved == .custom ? .balanced : saved
    }

    var quickOptimize: OptimizeSettings {
        OptimizeSettings(level: quickLevel, customFactor: 45, stripMetadata: true, convertIncompatible: true)
    }
}

// MARK: - Activity log

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let name: String
    let message: String
    let success: Bool
}
