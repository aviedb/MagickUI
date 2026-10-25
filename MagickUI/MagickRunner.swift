import Foundation

nonisolated struct MagickError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Small mutable box so background reader threads can hand data back.
private nonisolated final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs `magick` with an argument ARRAY (never a shell string), so filenames
/// with spaces, quotes or leading dashes can't be misinterpreted.
nonisolated struct MagickRunner {
    let executable: URL

    /// ImageMagick calls helper programs through PATH. A double-clicked Mac app has a
    /// minimal PATH, so we add the Homebrew directories.
    static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !extra.contains($0) }
        env["PATH"] = (extra + existing).joined(separator: ":")
        return env
    }

    /// Returns stdout. Throws `MagickError` (with magick's stderr) on a non-zero exit.
    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let exe = executable
        let env = MagickRunner.processEnvironment()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = arguments
                process.environment = env
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MagickError(
                        message: "Could not launch magick: \(error.localizedDescription)"))
                    return
                }

                // Read both pipes concurrently so a chatty process can't block on a full pipe.
                let outBox = DataBox()
                let errBox = DataBox()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let out = String(decoding: outBox.data, as: UTF8.self)
                let err = String(decoding: errBox.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = err.isEmpty
                        ? "magick exited with status \(process.terminationStatus)."
                        : err
                    continuation.resume(throwing: MagickError(message: message))
                }
            }
        }
    }
}
