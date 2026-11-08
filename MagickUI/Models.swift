import Foundation
import AppKit

// MARK: - Dropped images

nonisolated enum ItemStatus {
    case idle
    case running(String)
    case done(output: URL, inBytes: Int64, outBytes: Int64, note: String)
    case skipped(String)
    case failed(String)
}

struct ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    let byteSize: Int64
    var kind: MediaKind = .image
    /// Filled in for videos once ffprobe has read them.
    var video: VideoInfo? = nil
    /// 0...1 while a video is being encoded.
    var progress: Double? = nil
    /// Pixel size AFTER auto-orient (what magick will see when cropping). For a video: its displayed size.
    var pixelSize: CGSize? = nil
    var thumbnail: NSImage? = nil
    var status: ItemStatus = .idle

    var name: String { url.lastPathComponent }
}

// MARK: - Actions

nonisolated enum ImageAction: String, CaseIterable, Identifiable {
    case optimize, compress, convert, crop, resize, rotate, metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to size"
        case .convert: return "Convert format"
        case .crop: return "Crop"
        case .resize: return "Resize"
        case .rotate: return "Rotate & flip"
        case .metadata: return "Remove metadata"
        }
    }

    var subtitle: String {
        switch self {
        case .optimize: return "Shrink files without ever resizing them. Great for everyday use."
        case .compress: return "Get each image under a size you choose, like 200 KB."
        case .convert: return "Turn images into JPG, PNG, WebP, HEIC and more."
        case .crop: return "Drag to crop, with aspect-ratio presets and a live preview."
        case .resize: return "Set exact pixels or scale by percent."
        case .rotate: return "Rotate 90° or 180°, or mirror the image."
        case .metadata: return "Strip EXIF, GPS and camera data before sharing."
        }
    }

    var symbol: String {
        switch self {
        case .optimize: return "wand.and.stars"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .convert: return "arrow.triangle.2.circlepath"
        case .crop: return "crop"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .rotate: return "rotate.right"
        case .metadata: return "location.slash"
        }
    }

    /// Button verb, e.g. "Crop 3 images".
    var verb: String {
        switch self {
        case .optimize: return "Optimize"
        case .compress: return "Compress"
        case .convert: return "Convert"
        case .crop: return "Crop"
        case .resize: return "Resize"
        case .rotate: return "Apply to"
        case .metadata: return "Clean"
        }
    }

    /// Appended to the output file name.
    var suffix: String {
        switch self {
        case .optimize: return "_optimized"
        case .compress: return "_compressed"
        case .convert: return ""
        case .crop: return "_cropped"
        case .resize: return "_resized"
        case .rotate: return "_rotated"
        case .metadata: return "_clean"
        }
    }
}

// MARK: - Settings (Codable so watched-folder rules can be saved)

nonisolated enum SizeUnit: String, CaseIterable, Identifiable, Codable {
    case kb = "KB"
    case mb = "MB"

    var id: String { rawValue }
    /// Decimal (like Finder). Staying under N*1000 bytes also satisfies sites that count 1024.
    var bytes: Int64 { self == .kb ? 1_000 : 1_000_000 }
}

nonisolated enum CompressFormat: String, CaseIterable, Identifiable, Codable {
    case keep = "Same as original"
    case jpg = "JPG"
    case webp = "WebP"

    var id: String { rawValue }
}

nonisolated struct CompressSettings: Codable {
    var amount: Double = 200
    var unit: SizeUnit = .kb
    var format: CompressFormat = .keep
    var stripMetadata = true

    var targetBytes: Int64 {
        guard amount.isFinite, amount > 0 else { return 0 }
        return Int64(amount * Double(unit.bytes))
    }
}

nonisolated struct ConvertSettings: Codable {
    var target = "jpg"
    var useOther = false
    var otherExtension = ""
    var quality: Double = 90

    var resolvedExtension: String {
        let raw = useOther ? otherExtension : target
        return raw
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .lowercased()
    }
}

nonisolated enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case pixels = "Pixels"
    case percent = "Percent"

    var id: String { rawValue }
}

nonisolated struct ResizeSettings: Codable {
    var mode: ResizeMode = .pixels
    var width: Double = 1920
    var height: Double = 0
    var percent: Double = 50
    var keepAspect = true
    var shrinkOnly = true
}

nonisolated enum RotateOperation: String, CaseIterable, Identifiable, Codable {
    case right90 = "Rotate right 90°"
    case left90 = "Rotate left 90°"
    case turn180 = "Rotate 180°"
    case flipHorizontal = "Flip horizontal"
    case flipVertical = "Flip vertical"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .right90: return "rotate.right"
        case .left90: return "rotate.left"
        case .turn180: return "arrow.uturn.down"
        case .flipHorizontal: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .flipVertical: return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        }
    }

    /// magick: `-rotate` is clockwise for positive degrees; `-flop` mirrors left-right, `-flip` top-bottom.
    var arguments: [String] {
        switch self {
        case .right90: return ["-rotate", "90"]
        case .left90: return ["-rotate", "-90"]
        case .turn180: return ["-rotate", "180"]
        case .flipHorizontal: return ["-flop"]
        case .flipVertical: return ["-flip"]
        }
    }
}

// MARK: - Crop settings

enum CropRatioKind: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case r43 = "4:3"
    case r32 = "3:2"
    case r169 = "16:9"
    case r45 = "4:5"
    case custom = "Custom"

    var id: String { rawValue }

    /// width / height of the fixed presets.
    var fixedRatio: CGFloat? {
        switch self {
        case .square: return 1
        case .r43: return 4.0 / 3.0
        case .r32: return 3.0 / 2.0
        case .r169: return 16.0 / 9.0
        case .r45: return 4.0 / 5.0
        default: return nil
        }
    }
}

struct CropSettings {
    var kind: CropRatioKind = .free
    /// Flip between landscape and portrait (3:2 <-> 2:3).
    var swapped = false
    var customWidth: Double = 1
    var customHeight: Double = 1

    /// width / height the crop must keep, or nil for a free crop.
    func ratio(imageSize: CGSize?) -> CGFloat? {
        var value: CGFloat?
        switch kind {
        case .free:
            return nil
        case .original:
            if let size = imageSize, size.height > 0 { value = size.width / size.height }
        case .custom:
            if customWidth > 0, customHeight > 0 { value = CGFloat(customWidth / customHeight) }
        default:
            value = kind.fixedRatio
        }
        guard var ratio = value, ratio > 0, ratio.isFinite else { return nil }
        if swapped { ratio = 1 / ratio }
        return ratio
    }
}
