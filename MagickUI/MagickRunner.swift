import Foundation

nonisolated struct MagickError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Small mutable box so background reader threads can hand data back.
private nonisolated final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs a command-line tool (magick, jpegoptim, pngquant) with an argument ARRAY, never a shell string,
/// so filenames with spaces, quotes or leading dashes can't be misinterpreted.
nonisolated struct MagickRunner {
    let executable: URL

    /// Tools call helper programs through PATH. A double-clicked Mac app has a minimal PATH,
    /// so we add the Homebrew directories.
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

    /// Runs the tool and returns its exit status and output. Throws only if it can't be launched.
    func execute(_ arguments: [String]) async throws -> ProcessResult {
        let exe = executable
        let env = MagickRunner.processEnvironment()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
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
                        message: "Could not launch \(exe.lastPathComponent): \(error.localizedDescription)"))
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
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    /// Returns stdout. Throws `MagickError` (with the tool's stderr) on a non-zero exit.
    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let result = try await execute(arguments)
        guard result.status == 0 else {
            let message = result.stderr.isEmpty
                ? "\(executable.lastPathComponent) exited with status \(result.status)."
                : result.stderr
            throw MagickError(message: message)
        }
        return result.stdout
    }
}
