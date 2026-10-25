import Foundation

/// Finds the `magick` executable.
/// GUI apps do NOT inherit your shell PATH, so we probe the known Homebrew locations.
nonisolated enum MagickLocator {
    static let defaultsKey = "magickExecutablePath"

    private static let knownPaths = [
        "/opt/homebrew/bin/magick",              // Apple Silicon Homebrew
        "/usr/local/bin/magick",                 // Intel Homebrew
        "/opt/homebrew/opt/imagemagick/bin/magick",
        "/usr/local/opt/imagemagick/bin/magick"
    ]

    static func locate() -> URL? {
        var candidates: [String] = []
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            candidates.append(saved)
        }
        candidates.append(contentsOf: knownPaths)
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }
}
