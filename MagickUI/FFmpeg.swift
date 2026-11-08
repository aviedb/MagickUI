import Foundation
import CoreGraphics

// MARK: - Finding ffmpeg

nonisolated extension ExternalTool {
    static var ffmpeg: URL? { locate("ffmpeg") }
    static var ffprobe: URL? { locate("ffprobe") }
}

nonisolated struct VideoCancelled: Error {}

// MARK: - Running ffmpeg with live progress

private nonisolated final class FFBox: @unchecked Sendable {
    var data = Data()
}

/// Runs ffmpeg with an argument array and reports progress from its `-progress pipe:1` output.
/// One runner is used for a whole batch, so `cancel()` stops whatever is encoding right now.
nonisolated final class FFmpegRunner: @unchecked Sendable {
    let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelledFlag = false

    init(executable: URL) {
        self.executable = executable
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    /// `duration` is the length of the OUTPUT in seconds, used to turn ffmpeg's time into a fraction.
    func run(_ arguments: [String],
             duration: Double?,
             progress: @escaping @Sendable (Double) -> Void) async throws -> ProcessResult {
        let exe = executable
        let env = MagickRunner.processEnvironment()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if self.isCancelled {
                    continuation.resume(throwing: VideoCancelled())
                    return
                }

                let task = Process()
                task.executableURL = exe
                task.arguments = arguments
                task.environment = env
                task.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe

                self.lock.lock()
                self.process = task
                self.lock.unlock()

                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: MagickError(
                        message: "Could not launch ffmpeg: \(error.localizedDescription)"))
                    return
                }

                // stderr (with -loglevel error it is small) is read on its own thread.
                let errBox = FFBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                // stdout carries the progress lines; read them as they arrive.
                let handle = outPipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8) {
                            FFmpegRunner.report(line, duration: duration, progress: progress)
                        }
                    }
                }

                task.waitUntilExit()
                group.wait()

                self.lock.lock()
                self.process = nil
                self.lock.unlock()

                let err = String(decoding: errBox.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: ProcessResult(status: task.terminationStatus, stdout: "", stderr: err))
            }
        }
    }

    private static func report(_ line: String, duration: Double?, progress: @Sendable (Double) -> Void) {
        guard line.hasPrefix("out_time_us="), let duration, duration > 0 else { return }
        guard let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return }
        progress(min(1, max(0, microseconds / 1_000_000 / duration)))
    }
}

/// Last few lines of ffmpeg's error output, for showing to the user.
nonisolated func ffmpegErrorSummary(_ stderr: String, status: Int32) -> String {
    let lines = stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    if lines.isEmpty { return "ffmpeg exited with status \(status)." }
    return lines.suffix(3).joined(separator: "\n")
}

// MARK: - Which encoders this ffmpeg has

nonisolated enum FFmpegCapabilities {
    /// Parses `ffmpeg -encoders`.
    static func encoders(from listing: String) -> Set<String> {
        var result = Set<String>()
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, parts[1] != "=" else { continue }
            result.insert(String(parts[1]))
        }
        return result
    }
}

// MARK: - Reading a video's properties

nonisolated enum VideoProbe {
    static func probe(url: URL, ffprobe: URL) async -> VideoInfo? {
        let runner = MagickRunner(executable: ffprobe)
        let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "file:" + url.path]
        guard let result = try? await runner.execute(arguments), result.status == 0 else { return nil }
        return parse(Data(result.stdout.utf8))
    }

    static func parse(_ data: Data) -> VideoInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]

        // Ignore cover art that is stored as a "video" stream.
        let video = streams.first { stream in
            guard (stream["codec_type"] as? String) == "video" else { return false }
            let disposition = stream["disposition"] as? [String: Any]
            return (disposition?["attached_pic"] as? Int) != 1
        }
        guard let video, var width = video["width"] as? Int, var height = video["height"] as? Int else { return nil }

        // A phone video can be stored sideways with a rotation flag. Report the size as it is displayed.
        var rotation = 0
        if let sideData = video["side_data_list"] as? [[String: Any]] {
            for entry in sideData {
                if let value = entry["rotation"] as? Int { rotation = value }
                else if let value = entry["rotation"] as? Double { rotation = Int(value) }
            }
        }
        if rotation == 0, let tags = video["tags"] as? [String: Any], let text = tags["rotate"] as? String, let value = Int(text) {
            rotation = value
        }
        if abs(rotation) % 180 == 90 { swap(&width, &height) }

        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }

        var duration = Double(format["duration"] as? String ?? "") ?? 0
        if duration == 0 { duration = Double(video["duration"] as? String ?? "") ?? 0 }

        let transfer = video["color_transfer"] as? String ?? ""
        return VideoInfo(
            duration: duration,
            width: width,
            height: height,
            fps: frameRate(video["avg_frame_rate"] as? String) ?? frameRate(video["r_frame_rate"] as? String) ?? 30,
            videoCodec: video["codec_name"] as? String ?? "",
            audioCodec: audio?["codec_name"] as? String,
            pixelFormat: video["pix_fmt"] as? String ?? "yuv420p",
            bitRate: Int64(format["bit_rate"] as? String ?? "") ?? 0,
            isHDR: transfer == "smpte2084" || transfer == "arib-std-b67")
    }

    /// "30000/1001" -> 29.97
    private static func frameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        if parts.count == 1, parts[0] > 0 { return parts[0] }
        return nil
    }
}

// MARK: - Grabbing a single frame (thumbnails and previews)

nonisolated enum FrameGrabber {
    /// One frame at `time` seconds, scaled to at most `maxWidth` pixels wide. Works for any format ffmpeg reads.
    static func frame(url: URL, at time: Double, maxWidth: Int, ffmpeg: URL) async -> CGImage? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagickTools-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }

        let arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-ss", String(format: "%.3f", max(0, time)),
            "-i", "file:" + url.path,
            "-an", "-frames:v", "1", "-update", "1",
            "-vf", "scale='min(\(maxWidth),iw)':-2",
            "-q:v", "3",
            temp.path
        ]
        guard let result = try? await MagickRunner(executable: ffmpeg).execute(arguments), result.status == 0,
              FileManager.default.fileExists(atPath: temp.path) else { return nil }
        return ImagePreview.cgImage(url: temp, maxPixel: maxWidth)
    }
}

// MARK: - Showing times

/// 75.5 -> "1:15.5"
nonisolated func formatTime(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let rest = total - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, rest)
}

/// 3725 -> "1:02:05"
nonisolated func formatDuration(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}
