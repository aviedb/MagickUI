import Foundation
import CoreGraphics

nonisolated struct VideoJob {
    let url: URL
    let byteSize: Int64
    var info: VideoInfo?
    /// For Trim: the part to keep.
    var trim: TimeRange?
    /// For Export frame: the chosen moment, in seconds.
    var frameTime: Double?
}

/// Turns "a video + an action + settings" into ffmpeg runs. No UI state lives here, so the main window
/// and (later) watched folders can share it.
nonisolated struct VideoProcessor {
    let ffmpeg: URL
    let runner: FFmpegRunner
    var magick: MagickRunner? = nil
    var encoders: Set<String> = []
    var writableFormats: Set<String> = []

    /// What an action wrote into the working folder, before it is moved to its final place.
    private struct Produced {
        var files: [(url: URL, suffix: String)]
        var ext: String
        var note: String
    }

    private typealias Progress = @Sendable (Double) -> Void

    // MARK: Entry point

    func process(job: VideoJob,
                 action: VideoAction,
                 settings: VideoProcessorSettings,
                 outputDirectory: URL?,
                 reserved: inout Set<String>,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ItemStatus {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-video", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let produced: Produced
        switch action {
        case .optimize: produced = try await optimize(job, settings.optimize, workDir, progress)
        case .compress: produced = try await compress(job, settings.compress, workDir, progress)
        case .downscale: produced = try await downscale(job, settings.downscale, workDir, progress)
        case .convert: produced = try await convert(job, settings.convert, workDir, progress)
        case .trim: produced = try await trim(job, settings.trim, workDir, progress)
        case .frame: produced = try await exportFrames(job, settings, workDir, progress)
        }

        let directory = outputDirectory ?? job.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = OutputNaming.sanitize(job.url.deletingPathExtension().lastPathComponent)

        var finals: [URL] = []
        var totalBytes: Int64 = 0
        for file in produced.files {
            let destination = OutputNaming.uniqueURL(directory: directory,
                                                     stem: stem + file.suffix,
                                                     ext: produced.ext,
                                                     reserved: &reserved)
            try FileManager.default.moveItem(at: file.url, to: destination)
            finals.append(destination)
            totalBytes += fileSize(destination)
        }
        guard let first = finals.first else {
            throw MagickError(message: "ffmpeg finished but no output file was created.")
        }
        return .done(output: first, inBytes: job.byteSize, outBytes: totalBytes, note: produced.note)
    }

    // MARK: Smart optimize

    private func optimize(_ job: VideoJob, _ s: VideoOptimizeSettings, _ workDir: URL,
                          _ progress: @escaping Progress) async throws -> Produced {
        let info = try requireInfo(job)
        try requireEncoder(s.codec == .h264 ? "libx264" : "libx265")

        let crf = s.quality.crf(for: s.codec)
        let output = workDir.appendingPathComponent("out.mp4")
        var arguments = ["-i", input(job.url)]
        arguments += mapArguments(strip: s.stripMetadata)
        arguments += videoArguments(codec: s.codec, crf: crf, speed: s.speed, info: info)
        arguments += audioArguments(info)
        arguments += ["-movflags", "+faststart", output.path]
        try await run(arguments, duration: info.duration, progress)

        let outBytes = fileSize(output)
        if outBytes >= job.byteSize {
            throw ItemSkip(message: "Re-encoding wouldn't make this video smaller (\(formatBytes(job.byteSize))).")
        }
        var note = "\(s.codec.rawValue), CRF \(crf)"
        if info.isHDR && s.codec == .h264 { note += ", HDR became SDR (HEVC keeps HDR)" }
        return Produced(files: [(output, "_optimized")], ext: "mp4", note: note)
    }

    // MARK: Compress to a target size

    private func compress(_ job: VideoJob, _ s: VideoCompressSettings, _ workDir: URL,
                          _ progress: @escaping Progress) async throws -> Produced {
        let info = try requireInfo(job)
        guard info.duration > 0 else { throw MagickError(message: "Couldn't read this video's length.") }
        let target = s.targetBytes
        guard target > 0 else { throw MagickError(message: "Enter a target size above 0.") }
        if job.byteSize <= target {
            throw ItemSkip(message: "Already \(formatBytes(job.byteSize)), under the target.")
        }
        try requireEncoder(s.codec == .h264 ? "libx264" : "libx265")

        // Bit budget: a little under the target, because the container and rate control add overhead.
        let totalBps = Double(target) * 8 * 0.95 / info.duration
        let audioBps = info.hasAudio ? (totalBps > 900_000 ? 128_000 : 64_000) : 0
        var videoBps = Int(totalBps) - audioBps
        guard videoBps >= 60_000 else {
            throw MagickError(message: "\(formatBytes(target)) is too small for a \(formatDuration(info.duration)) video. Try a larger size.")
        }

        var height = info.height
        if s.allowDownscale {
            height = fittingHeight(info: info, videoBps: videoBps, codec: s.codec)
        }
        let scale = height != info.height ? "scale=-2:\(height)" : nil

        var attempt = 0
        var output = workDir.appendingPathComponent("out-0.mp4")
        var outBytes: Int64 = 0
        while true {
            output = workDir.appendingPathComponent("out-\(attempt).mp4")
            try await twoPass(job: job, info: info, settings: s, videoBps: videoBps, audioBps: audioBps,
                              scale: scale, output: output, workDir: workDir, progress: progress)
            outBytes = fileSize(output)
            // Rate control can miss by a few percent. One correction pass is usually enough.
            if outBytes > target, attempt < 2 {
                let corrected = Int(Double(videoBps) * Double(target) / Double(outBytes) * 0.97)
                if corrected < 60_000 { break }
                videoBps = corrected
                attempt += 1
                continue
            }
            break
        }

        var note = "\(s.codec.rawValue), \(videoBps / 1000) kbps"
        if height != info.height { note += ", scaled to \(height)p" }
        if outBytes > target { note += ", \(formatBytes(outBytes - target)) over the target" }
        return Produced(files: [(output, "_compressed")], ext: "mp4", note: note)
    }

    /// Picks the largest standard height at which the bit budget still gives a decent picture.
    private func fittingHeight(info: VideoInfo, videoBps: Int, codec: VideoCodec) -> Int {
        let ladder = [2160, 1440, 1080, 720, 540, 480, 360, 240]
        let minimumBitsPerPixel = codec == .h264 ? 0.045 : 0.032
        let fps = max(1, min(info.fps, 60))

        var height = info.height
        var width = info.width
        func bitsPerPixel() -> Double { Double(videoBps) / (Double(width) * Double(height) * fps) }

        while bitsPerPixel() < minimumBitsPerPixel {
            guard let next = ladder.first(where: { $0 < height }) else { break }
            width = Int((Double(width) * Double(next) / Double(height)).rounded())
            height = next
        }
        return height
    }

    private func twoPass(job: VideoJob, info: VideoInfo, settings s: VideoCompressSettings,
                         videoBps: Int, audioBps: Int, scale: String?, output: URL, workDir: URL,
                         progress: @escaping Progress) async throws {
        let passLog = workDir.appendingPathComponent("pass").path
        let statsFile = workDir.appendingPathComponent("x265.log").path
        let filter: [String] = scale.map { ["-vf", $0] } ?? []

        var firstPass = ["-i", input(job.url), "-map", "0:v:0"] + filter
        var secondPass = ["-i", input(job.url), "-map", "0:v:0", "-map", "0:a?"]
            + mapStripArguments(strip: s.stripMetadata) + filter

        switch s.codec {
        case .h264:
            let common = ["-c:v", "libx264", "-preset", s.speed.preset, "-b:v", String(videoBps), "-pix_fmt", "yuv420p"]
            firstPass += common + ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "/dev/null"]
            secondPass += common + ["-pass", "2", "-passlogfile", passLog]
        case .hevc:
            let pixelFormat = info.isTenBit ? "yuv420p10le" : "yuv420p"
            let common = ["-c:v", "libx265", "-preset", s.speed.preset, "-b:v", String(videoBps),
                          "-tag:v", "hvc1", "-pix_fmt", pixelFormat]
            firstPass += common + ["-x265-params", "pass=1:stats=\(statsFile):log-level=error", "-an", "-f", "null", "/dev/null"]
            secondPass += common + ["-x265-params", "pass=2:stats=\(statsFile):log-level=error"]
        }
        if info.hasAudio {
            secondPass += ["-c:a", "aac", "-b:a", String(audioBps)]
        } else {
            secondPass += ["-an"]
        }
        secondPass += ["-movflags", "+faststart", output.path]

        try await run(firstPass, duration: info.duration) { progress($0 * 0.4) }
        try await run(secondPass, duration: info.duration) { progress(0.4 + $0 * 0.6) }
    }

    // MARK: Downscale

    private func downscale(_ job: VideoJob, _ s: VideoDownscaleSettings, _ workDir: URL,
                           _ progress: @escaping Progress) async throws -> Produced {
        let info = try requireInfo(job)
        try requireEncoder(s.codec == .h264 ? "libx264" : "libx265")

        let targetHeight = s.resolvedHeight
        let needsScale = s.shrinkOnly ? info.height > targetHeight : info.height != targetHeight
        let needsFPS = s.fpsCap > 0 && info.fps > Double(s.fpsCap) + 0.5
        guard needsScale || needsFPS else {
            throw ItemSkip(message: "Already \(info.height)p or smaller, so there's nothing to reduce.")
        }

        var filters: [String] = []
        if needsScale { filters.append("scale=-2:\(targetHeight)") }
        if needsFPS { filters.append("fps=\(s.fpsCap)") }

        let crf = s.quality.crf(for: s.codec)
        let output = workDir.appendingPathComponent("out.mp4")
        var arguments = ["-i", input(job.url)]
        arguments += mapArguments(strip: s.stripMetadata)
        arguments += ["-vf", filters.joined(separator: ",")]
        arguments += videoArguments(codec: s.codec, crf: crf, speed: s.speed, info: info)
        arguments += audioArguments(info)
        arguments += ["-movflags", "+faststart", output.path]
        try await run(arguments, duration: info.duration, progress)

        var parts: [String] = []
        if needsScale { parts.append("\(info.height)p → \(targetHeight)p") }
        if needsFPS { parts.append("\(Int(info.fps.rounded())) → \(s.fpsCap) fps") }
        let suffix = needsScale ? "_\(targetHeight)p" : "_\(s.fpsCap)fps"
        return Produced(files: [(output, suffix)], ext: "mp4", note: parts.joined(separator: ", "))
    }

    // MARK: Convert

    private func convert(_ job: VideoJob, _ s: VideoConvertSettings, _ workDir: URL,
                         _ progress: @escaping Progress) async throws -> Produced {
        let format = s.format
        let info = job.info
        if !(format.supportsRemux && s.remux) {
            for encoder in format.requiredEncoders { try requireEncoder(encoder) }
        }
        if format.group == .audio, info?.hasAudio == false {
            throw MagickError(message: "This video has no audio track to extract.")
        }

        let output = workDir.appendingPathComponent("out.\(format.ext)")
        var arguments = ["-i", input(job.url)]
        var note = format.title

        switch format {
        case .mp4H264, .mp4HEVC, .mov, .mkv:
            if s.remux {
                arguments += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
                if info?.videoCodec == "hevc", format != .mkv { arguments += ["-tag:v", "hvc1"] }
                note += ", copied without re-encoding"
            } else {
                let codec: VideoCodec = format == .mp4HEVC ? .hevc : .h264
                let crf = s.quality.crf(for: codec)
                arguments += mapArguments(strip: false)
                arguments += videoArguments(codec: codec, crf: crf, speed: s.speed, info: info)
                arguments += audioArguments(info)
                note += ", \(codec.rawValue) CRF \(crf)"
            }
            if format != .mkv { arguments += ["-movflags", "+faststart"] }

        case .webm:
            arguments += ["-map", "0:v:0", "-map", "0:a?",
                          "-c:v", "libvpx-vp9", "-crf", String(s.quality.vp9CRF), "-b:v", "0",
                          "-row-mt", "1", "-deadline", "good", "-cpu-used", s.speed == .fast ? "5" : "2",
                          "-pix_fmt", "yuv420p"]
            arguments += info?.hasAudio == false ? ["-an"] : ["-c:a", "libopus", "-b:a", "128k"]

        case .avi:
            arguments += ["-map", "0:v:0", "-map", "0:a?",
                          "-c:v", "mpeg4", "-q:v", String(s.quality.mpeg4Scale), "-pix_fmt", "yuv420p"]
            arguments += info?.hasAudio == false ? ["-an"] : ["-c:a", "libmp3lame", "-q:a", "4"]

        case .gif:
            let width = s.gifWidth
            let scale = width > 0 ? "scale='min(\(width),iw)':-1:flags=lanczos," : ""
            let filter = "fps=\(s.gifFPS),\(scale)split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"
            arguments += ["-an", "-vf", filter, "-loop", "0"]
            note += ", \(s.gifFPS) fps" + (width > 0 ? ", up to \(width) px wide" : "")
            if let info, info.duration > 30 { note += ". Long GIFs get very large" }

        case .webp:
            let width = s.gifWidth
            let scale = width > 0 ? ",scale='min(\(width),iw)':-1:flags=lanczos" : ""
            arguments += ["-an", "-vf", "fps=\(s.gifFPS)\(scale)",
                          "-c:v", "libwebp", "-lossless", "0", "-q:v", String(s.quality.webpQuality), "-loop", "0"]
            note += ", \(s.gifFPS) fps"

        case .mp3:
            arguments += ["-vn", "-c:a", "libmp3lame", "-q:a", String(s.quality.mp3VBR)]
        case .m4a:
            arguments += ["-vn", "-c:a", "aac", "-b:a", s.quality.aacBitrate]
        case .wav:
            arguments += ["-vn", "-c:a", "pcm_s16le"]
        case .flac:
            arguments += ["-vn", "-c:a", "flac"]
        case .opus:
            arguments += ["-vn", "-c:a", "libopus", "-b:a", s.quality.opusBitrate]
        }

        arguments.append(output.path)
        try await run(arguments, duration: info?.duration, progress)

        let sameFormat = ImageFiles.normalizedExtension(job.url.pathExtension) == ImageFiles.normalizedExtension(format.ext)
        return Produced(files: [(output, sameFormat ? "_converted" : "")], ext: format.ext, note: note)
    }

    // MARK: Trim

    private func trim(_ job: VideoJob, _ s: VideoTrimSettings, _ workDir: URL,
                      _ progress: @escaping Progress) async throws -> Produced {
        let info = try requireInfo(job)
        guard let range = job.trim else { throw ItemSkip(message: "No trim range set for this video.") }
        let length = range.end - range.start
        guard length > 0.05 else { throw MagickError(message: "The trim range is too short.") }
        if range.start <= 0.01 && range.end >= info.duration - 0.01 {
            throw ItemSkip(message: "The range covers the whole video.")
        }

        let inExt = job.url.pathExtension.lowercased()
        let start = String(format: "%.3f", range.start)
        let duration = String(format: "%.3f", length)
        var arguments = ["-ss", start, "-i", input(job.url), "-t", duration, "-map", "0:v:0", "-map", "0:a?"]

        let outExt: String
        let note: String
        switch s.mode {
        case .fast:
            // Copying can only cut on keyframes, so the start may be a little earlier than asked.
            outExt = inExt.isEmpty ? "mp4" : inExt
            arguments += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
            note = "\(formatTime(range.start)) – \(formatTime(range.end)), no re-encode"
        case .precise:
            let codec: VideoCodec = info.videoCodec == "hevc" ? .hevc : .h264
            try requireEncoder(codec == .h264 ? "libx264" : "libx265")
            outExt = ["mp4", "mov", "mkv", "m4v"].contains(inExt) ? inExt : "mp4"
            arguments += videoArguments(codec: codec, crf: codec == .h264 ? 18 : 22, speed: .balanced, info: info)
            arguments += info.hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
            if outExt != "mkv" { arguments += ["-movflags", "+faststart"] }
            note = "\(formatTime(range.start)) – \(formatTime(range.end))"
        }

        let output = workDir.appendingPathComponent("out.\(outExt)")
        arguments.append(output.path)
        try await run(arguments, duration: length, progress)
        return Produced(files: [(output, "_trimmed")], ext: outExt, note: note)
    }

    // MARK: Export frames

    private func exportFrames(_ job: VideoJob, _ settings: VideoProcessorSettings, _ workDir: URL,
                              _ progress: @escaping Progress) async throws -> Produced {
        let info = try requireInfo(job)

        // The image format is checked with the same rules as the image Convert tool.
        let probeJob = ImageJob(url: workDir.appendingPathComponent("frame.png"), byteSize: 0)
        var imageSettings = ProcessorSettings()
        imageSettings.convert = settings.frameFormat
        let plan = try ImageProcessor.makePlan(action: .convert, settings: imageSettings,
                                               job: probeJob, writableFormats: writableFormats)

        let times: [Double]
        if settings.frame.evenly {
            let count = max(1, min(settings.frame.count, 200))
            times = (0..<count).map { info.duration * (Double($0) + 0.5) / Double(count) }
        } else {
            times = [min(max(job.frameTime ?? 0, 0), max(info.duration - 0.05, 0))]
        }

        var files: [(url: URL, suffix: String)] = []
        for (index, time) in times.enumerated() {
            let png = workDir.appendingPathComponent("frame-\(index).png")
            let arguments = ["-ss", String(format: "%.3f", time), "-i", input(job.url),
                             "-an", "-frames:v", "1", "-update", "1", png.path]
            try await run(arguments, duration: nil) { _ in }
            guard FileManager.default.fileExists(atPath: png.path) else {
                throw MagickError(message: "Couldn't read a frame at \(formatTime(time)).")
            }

            let final: URL
            if plan.ext == "png" {
                final = png
            } else {
                guard let magick else { throw MagickError(message: "ImageMagick is needed to save frames as \(plan.ext.uppercased()).") }
                final = workDir.appendingPathComponent("frame-\(index).\(plan.ext)")
                try await magick.run(plan.arguments(firstFrame(png.path), final.path))
            }

            let label = String(format: "%.2f", time).replacingOccurrences(of: ".", with: "-")
            files.append((final, "_frame_\(label)s"))
            progress(Double(index + 1) / Double(times.count))
        }

        let note = files.count == 1 ? "frame at \(formatTime(times[0]))" : "\(files.count) frames"
        return Produced(files: files, ext: plan.ext, note: note)
    }

    // MARK: Shared pieces

    private func input(_ url: URL) -> String { "file:" + url.path }

    private func requireInfo(_ job: VideoJob) throws -> VideoInfo {
        guard let info = job.info else {
            throw MagickError(message: "Couldn't read this video. Is ffprobe installed? Run “brew install ffmpeg”.")
        }
        return info
    }

    private func requireEncoder(_ name: String) throws {
        if !encoders.isEmpty && !encoders.contains(name) {
            throw MagickError(message: "Your ffmpeg doesn't include the \(name) encoder. Try “brew reinstall ffmpeg”.")
        }
    }

    /// First video stream plus every audio stream; optionally drop metadata and chapters.
    private func mapArguments(strip: Bool) -> [String] {
        ["-map", "0:v:0", "-map", "0:a?"] + mapStripArguments(strip: strip)
    }

    private func mapStripArguments(strip: Bool) -> [String] {
        strip ? ["-map_metadata", "-1", "-map_chapters", "-1"] : []
    }

    private func videoArguments(codec: VideoCodec, crf: Int, speed: EncodeSpeed, info: VideoInfo?) -> [String] {
        switch codec {
        case .h264:
            return ["-c:v", "libx264", "-preset", speed.preset, "-crf", String(crf), "-pix_fmt", "yuv420p"]
        case .hevc:
            // Keep 10-bit sources 10-bit, so HDR phone videos don't turn flat.
            let pixelFormat = info?.isTenBit == true ? "yuv420p10le" : "yuv420p"
            return ["-c:v", "libx265", "-preset", speed.preset, "-crf", String(crf),
                    "-tag:v", "hvc1", "-pix_fmt", pixelFormat, "-x265-params", "log-level=error"]
        }
    }

    /// AAC audio is copied untouched. Anything else becomes AAC at 128 kbps.
    private func audioArguments(_ info: VideoInfo?) -> [String] {
        guard let info, info.hasAudio else { return info == nil ? ["-c:a", "aac", "-b:a", "128k"] : ["-an"] }
        return info.audioCodec == "aac" ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "128k"]
    }

    private func run(_ arguments: [String], duration: Double?,
                     _ progress: @escaping Progress) async throws {
        let full = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats"] + arguments
        let result = try await runner.run(full, duration: duration, progress: progress)
        if runner.isCancelled { throw VideoCancelled() }
        guard result.status == 0 else {
            throw MagickError(message: ffmpegErrorSummary(result.stderr, status: result.status))
        }
    }
}
