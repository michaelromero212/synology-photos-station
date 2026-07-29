import Dispatch
import Foundation
import Vapor

/// Runs an external binary without blocking an event loop thread.
///
/// The media pipeline is three shell-outs — `exiftool`, `vips`, `ffprobe`/
/// `ffmpeg` — because each is far better at its job than anything available
/// in-process, and because originals must never be re-encoded by us.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 180
    ) async throws -> Result {
        guard let executableURL = resolve(executable) else {
            throw ShellError.notFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain continuously rather than after exit: a process that fills
            // the 64 KB pipe buffer would otherwise deadlock waiting for us.
            // The buffers live in a locked box because the readability handlers
            // run on arbitrary threads.
            let output = OutputBox()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                output.appendStdout(handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                output.appendStderr(handle.availableData)
            }

            let resumed = ManagedAtomicFlag()

            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Sweep anything buffered between the last read and exit.
                output.appendStdout(outPipe.fileHandleForReading.availableData)
                output.appendStderr(errPipe.fileHandleForReading.availableData)
                let snapshot = output.snapshot()
                if resumed.testAndSet() {
                    continuation.resume(returning: Result(
                        status: finished.terminationStatus,
                        stdout: snapshot.stdout,
                        stderr: snapshot.stderr
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                if resumed.testAndSet() { continuation.resume(throwing: error) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                if resumed.testAndSet() {
                    continuation.resume(throwing: ShellError.timedOut(executable, timeout))
                }
            }
        }
    }

    /// Runs and throws unless the process exits 0.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 180
    ) async throws -> Result {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ShellError.failed(executable, result.status, result.stderrText)
        }
        return result
    }

    /// Whether a binary is on PATH — used at boot so a missing dependency is a
    /// startup warning rather than a mystery failure on the first upload.
    static func isAvailable(_ executable: String) -> Bool {
        resolve(executable) != nil
    }

    private static func resolve(_ executable: String) -> URL? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable) : nil
        }
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        // Homebrew on Apple silicon isn't on a login shell's default PATH when
        // the server is launched from a GUI context.
        for path in searchPaths + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Pipe buffers, guarded — `readabilityHandler` fires on arbitrary threads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); stdout.append(chunk); lock.unlock()
    }

    func appendStderr(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); stderr.append(chunk); lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock(); defer { lock.unlock() }
        return (stdout, stderr)
    }
}

/// Minimal test-and-set so the timeout race and the termination handler can't
/// both resume the same continuation.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns true exactly once, for the first caller.
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

enum ShellError: Error, CustomStringConvertible {
    case notFound(String)
    case failed(String, Int32, String)
    case timedOut(String, TimeInterval)

    var description: String {
        switch self {
        case .notFound(let executable):
            return "\(executable) is not installed or not on PATH."
        case .failed(let executable, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) exited \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        case .timedOut(let executable, let seconds):
            return "\(executable) did not finish within \(Int(seconds))s."
        }
    }
}
