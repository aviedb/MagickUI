import Foundation
import CoreGraphics
import ImageIO

// MARK: - Which files / formats the app handles

nonisolated enum ImageFiles {
    /// Input formats accepted by the drop zone (images only).
    static let accepted: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"]

    /// Output extensions we refuse: documents / non-image containers.
    static let blockedOutputs: Set<String> = [
        "pdf", "ps", "ps2", "ps3", "eps", "eps2", "eps3", "epsf", "epsi", "epdf", "epi", "ept",
        "html", "htm", "shtml", "txt", "text", "svg", "msvg", "json", "xml"
    ]

    /// Output formats where a quality setting matters.
    static let lossyOutputs: Set<String> = ["jpg", "jpeg", "webp", "heic", "heif", "avif", "jp2", "jxl"]

    /// Output formats that can't hold transparency (we flatten onto white first).
    static let noAlphaOutputs: Set<String> = ["jpg", "jpeg", "bmp"]

    /// jpeg == jpg, tiff == tif, for "is this the same format?" checks.
    static func normalizedExtension(_ url: URL) -> String {
        normalizedExtension(url.pathExtension)
    }

    static func normalizedExtension(_ ext: String) -> String {
        let e = ext.lowercased()
        switch e {
        case "jpeg": return "jpg"
        case "tiff": return "tif"
        case "heif": return "heic"
        default: return e
        }
    }

    /// Parses `magick -list format` and returns the (uppercase) names ImageMagick can WRITE.
    static func writableFormats(from listing: String) -> Set<String> {
        var result = Set<String>()
        for line in listing.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 3 else { continue }
            let mode = Array(tokens[2])
            guard mode.count == 3, mode.allSatisfy({ "r-w+".contains($0) }) else { continue }
            guard mode[1] == "w" else { continue }
            let name = tokens[0].trimmingCharacters(in: CharacterSet(charactersIn: "*")).uppercased()
            if !name.isEmpty { result.insert(name) }
        }
        return result
    }
}

// MARK: - Small shared helpers

nonisolated struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

nonisolated struct ItemSkip: Error {
    let message: String
}

/// Always read only the first frame/page (`[0]`), so a multi-frame input can never
/// produce numbered output files like `out-0.jpg`.
nonisolated func firstFrame(_ path: String) -> String {
    path + "[0]"
}

nonisolated func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

nonisolated func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Quotes a string for DISPLAY / copy-paste into Terminal (the app itself never uses a shell).
nonisolated func shellQuote(_ string: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if !string.isEmpty && string.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return string
    }
    return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Output naming

nonisolated enum OutputNaming {
    /// Characters ImageMagick treats specially in file names (frame selectors, globs, printf patterns).
    private static let unsafeCharacters = CharacterSet(charactersIn: "[]{}*?%")

    static func sanitize(_ name: String) -> String {
        String(name.unicodeScalars.map { unsafeCharacters.contains($0) ? Character("_") : Character($0) })
    }

    /// `stem.ext`, or `stem 2.ext`, `stem 3.ext`… if it exists or was already planned in this run.
    static func uniqueURL(directory: URL, stem: String, ext: String, reserved: inout Set<String>) -> URL {
        let fm = FileManager.default

        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? stem : "\(stem) \(n)"
            return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }

        var n = 1
        var url = candidate(n)
        while fm.fileExists(atPath: url.path) || reserved.contains(url.path.lowercased()) {
            n += 1
            url = candidate(n)
        }
        reserved.insert(url.path.lowercased())
        return url
    }
}

// MARK: - Safe input paths

/// Paths containing characters ImageMagick would interpret (`[0]` frame selectors, `*`/`?` globs,
/// `%d` patterns) are exposed to magick through a temporary symlink with a plain name.
/// The temporary links are removed as soon as the body finishes.
nonisolated enum InputResolver {
    private static let special = CharacterSet(charactersIn: "[]{}*?%")

    static func withPaths<T>(_ urls: [URL], _ body: ([String]) async throws -> T) async throws -> T {
        var created: [URL] = []
        defer {
            for directory in created { try? FileManager.default.removeItem(at: directory) }
        }

        var paths: [String] = []
        for url in urls {
            let path = url.path
            if path.unicodeScalars.contains(where: { special.contains($0) }) {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MagickTools-inputs", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                created.append(directory)
                let ext = url.pathExtension
                let link = directory.appendingPathComponent(ext.isEmpty ? "input" : "input.\(ext)")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
                paths.append(link.path)
            } else {
                paths.append(path)
            }
        }
        return try await body(paths)
    }
}

// MARK: - Previews (ImageIO)

nonisolated enum ImagePreview {
    /// An upright (EXIF-orientation applied) CGImage no larger than `maxPixel` on its long side.
    static func cgImage(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
