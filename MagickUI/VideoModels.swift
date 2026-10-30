import Foundation

// MARK: - Kinds of media

nonisolated enum MediaKind: String {
    case image
    case video
}

// MARK: - What we know about a video (from ffprobe)

nonisolated struct VideoInfo {
    var duration: Double
    /// Width and height as the video is DISPLAYED (a phone video stored sideways is swapped).
    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String
    var audioCodec: String?
    var pixelFormat: String
    var bitRate: Int64
    var isHDR: Bool

    var hasAudio: Bool { audioCodec != nil }
    var isTenBit: Bool { pixelFormat.contains("10") || pixelFormat.contains("12") }
}

nonisolated struct TimeRange {
    var start: Double
    var end: Double
}

// MARK: - Actions

nonisolated enum VideoAction: String, CaseIterable, Identifiable {
    case optimize, compress, downscale, convert, trim, frame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimize: return "Smart optimize"
        case .compress: return "Compress to size"
        case .downscale: return "Downscale"
        case .convert: return "Convert format"
        case .trim: return "Trim"
        case .frame: return "Export frame"
        }
    }

    var subtitle: String {
        switch self {
        case .optimize: return "Re-encode with H.264 or HEVC for a much smaller file at the same look."
        case .compress: return "Get each video under a size you choose, like 25 MB."
        case .downscale: return "Reduce the resolution or frame rate, such as 4K down to 1080p."
        case .convert: return "MP4, MOV, MKV, WebM, GIF, animated WebP, or just the audio."
        case .trim: return "Cut the start and end, with a preview of the frames."
        case .frame: return "Save any frame as an image, in any image format."
        }
    }

    var symbol: String {
        switch self {
        case .optimize: return "wand.and.stars"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .downscale: return "arrow.down.right.square"
        case .convert: return "arrow.triangle.2.circlepath"
        case .trim: return "scissors"
        case .frame: return "camera.viewfinder"
        }
    }

    var verb: String {
        switch self {
        case .optimize: return "Optimize"
        case .compress: return "Compress"
        case .downscale: return "Downscale"
        case .convert: return "Convert"
        case .trim: return "Trim"
        case .frame: return "Export frames from"
        }
    }
}

// MARK: - Codecs and quality

nonisolated enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"

    var id: String { rawValue }
}

nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case high = "High quality"
    case balanced = "Balanced"
    case small = "Smaller file"

    var id: String { rawValue }

    /// x264 / x265 constant rate factor. Lower means better quality and a bigger file.
    func crf(for codec: VideoCodec) -> Int {
        switch (codec, self) {
        case (.h264, .high): return 20
        case (.h264, .balanced): return 23
        case (.h264, .small): return 28
        case (.hevc, .high): return 24
        case (.hevc, .balanced): return 28
        case (.hevc, .small): return 32
        }
    }

    var vp9CRF: Int {
        switch self {
        case .high: return 28
        case .balanced: return 32
        case .small: return 38
        }
    }

    var mpeg4Scale: Int {
        switch self {
        case .high: return 3
        case .balanced: return 5
        case .small: return 8
        }
    }

    var webpQuality: Int {
        switch self {
        case .high: return 85
        case .balanced: return 70
        case .small: return 50
        }
    }

    var mp3VBR: Int {
        switch self {
        case .high: return 0
        case .balanced: return 2
        case .small: return 5
        }
    }

    var aacBitrate: String {
        switch self {
        case .high: return "256k"
        case .balanced: return "192k"
        case .small: return "128k"
        }
    }

    var opusBitrate: String {
        switch self {
        case .high: return "160k"
        case .balanced: return "128k"
        case .small: return "80k"
        }
    }
}

nonisolated enum EncodeSpeed: String, CaseIterable, Identifiable, Codable {
    case fast = "Fast"
    case balanced = "Balanced"
    case slow = "Slower, smaller"

    var id: String { rawValue }

    var preset: String {
        switch self {
        case .fast: return "veryfast"
        case .balanced: return "medium"
        case .slow: return "slow"
        }
    }
}

// MARK: - Output formats for Convert

nonisolated enum VideoFormat: String, CaseIterable, Identifiable, Codable {
    case mp4H264, mp4HEVC, mov, mkv, webm, avi, gif, webp, mp3, m4a, wav, flac, opus

    var id: String { rawValue }

    enum Group: String {
        case video = "Video"
        case animated = "Animated image"
        case audio = "Audio only"
    }

    var group: Group {
        switch self {
        case .mp4H264, .mp4HEVC, .mov, .mkv, .webm, .avi: return .video
        case .gif, .webp: return .animated
        case .mp3, .m4a, .wav, .flac, .opus: return .audio
        }
    }

    var title: String {
        switch self {
        case .mp4H264: return "MP4 (H.264)"
        case .mp4HEVC: return "MP4 (HEVC)"
        case .mov: return "MOV"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .avi: return "AVI"
        case .gif: return "GIF"
        case .webp: return "Animated WebP"
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        }
    }

    var ext: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .mov: return "mov"
        case .mkv: return "mkv"
        case .webm: return "webm"
        case .avi: return "avi"
        case .gif: return "gif"
        case .webp: return "webp"
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        case .wav: return "wav"
        case .flac: return "flac"
        case .opus: return "opus"
        }
    }

    /// ffmpeg encoders this format needs when the streams are re-encoded.
    var requiredEncoders: [String] {
        switch self {
        case .mp4H264, .mov, .mkv: return ["libx264", "aac"]
        case .mp4HEVC: return ["libx265", "aac"]
        case .webm: return ["libvpx-vp9", "libopus"]
        case .avi: return ["mpeg4", "libmp3lame"]
        case .gif: return []
        case .webp: return ["libwebp"]
        case .mp3: return ["libmp3lame"]
        case .m4a: return ["aac"]
        case .wav: return ["pcm_s16le"]
        case .flac: return ["flac"]
        case .opus: return ["libopus"]
        }
    }

    /// Containers that can copy the streams without re-encoding.
    var supportsRemux: Bool {
        switch self {
        case .mp4H264, .mp4HEVC, .mov, .mkv: return true
        default: return false
        }
    }

    var usesQuality: Bool {
        switch self {
        case .wav, .flac, .gif: return false
        default: return true
        }
    }
}

// MARK: - Settings

nonisolated struct VideoOptimizeSettings: Codable {
    var codec: VideoCodec = .h264
    var quality: VideoQuality = .balanced
    var speed: EncodeSpeed = .balanced
    var stripMetadata = true
}

nonisolated struct VideoCompressSettings: Codable {
    var amount: Double = 25
    var unit: SizeUnit = .mb
    var codec: VideoCodec = .h264
    var speed: EncodeSpeed = .balanced
    /// Lower the resolution when the size is too small for the current one to look good.
    var allowDownscale = true
    var stripMetadata = true

    var targetBytes: Int64 {
        guard amount.isFinite, amount > 0 else { return 0 }
        return Int64(amount * Double(unit.bytes))
    }
}

nonisolated struct VideoDownscaleSettings: Codable {
    var height = 720
    var useCustom = false
    var customHeight: Double = 720
    var shrinkOnly = true
    /// 0 keeps the original frame rate.
    var fpsCap = 0
    var codec: VideoCodec = .h264
    var quality: VideoQuality = .balanced
    var speed: EncodeSpeed = .balanced
    var stripMetadata = true

    var resolvedHeight: Int {
        let value = useCustom ? Int(customHeight) : height
        return max(16, value - value % 2)      // video heights must be even
    }
}

nonisolated enum TrimMode: String, CaseIterable, Identifiable, Codable {
    case precise = "Precise (re-encodes)"
    case fast = "Fast (no re-encode)"

    var id: String { rawValue }
}

nonisolated struct VideoTrimSettings: Codable {
    var mode: TrimMode = .precise
}

nonisolated struct VideoConvertSettings: Codable {
    var format: VideoFormat = .mp4H264
    var quality: VideoQuality = .balanced
    var speed: EncodeSpeed = .balanced
    /// Copy the streams instead of re-encoding (instant, no quality loss) when the container allows it.
    var remux = false
    var gifFPS = 12
    /// 0 keeps the original width.
    var gifWidth = 480
}

nonisolated struct FrameSettings: Codable {
    /// false: the frame at the playhead. true: several frames spaced evenly through the video.
    var evenly = false
    var count = 5
}

nonisolated struct VideoProcessorSettings {
    var optimize = VideoOptimizeSettings()
    var compress = VideoCompressSettings()
    var downscale = VideoDownscaleSettings()
    var convert = VideoConvertSettings()
    var trim = VideoTrimSettings()
    var frame = FrameSettings()
    /// The image format for exported frames (same options as the image Convert tool).
    var frameFormat = ConvertSettings(target: "png", useOther: false, otherExtension: "", quality: 90)
}
