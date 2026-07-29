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

        // Output goes to temporary FILES, not pipes.
        //
        // Pipes are the obvious choice and they deadlocked in production: the
        // parent retains the write descriptor, so the read end may never see
        // EOF, and a reader blocks forever after the child has already exited.
        // Closing the parent's copy and draining on background threads made it
        // rarer without eliminating it — worker lanes still hung permanently
        // with no subprocess alive and no error to show for it.
        //
        // Files have none of those semantics: no 64 KB buffer to fill, no EOF
        // handshake, no possible deadlock. Every consumer here (exiftool JSON,
        // ffprobe JSON, vips diagnostics) produces small output, and vips
        // writes its real output to disk anyway.
        let scratch = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let outURL = scratch.appendingPathComponent("framestation-\(token).out")
        let errURL = scratch.appendingPathComponent("framestation-\(token).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        func cleanUp() {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outHandle
            process.standardError = errHandle

            let resumed = ManagedAtomicFlag()

            process.terminationHandler = { finished in
                try? outHandle.close()
                try? errHandle.close()
                let stdout = (try? Data(contentsOf: outURL)) ?? Data()
                let stderr = (try? Data(contentsOf: errURL)) ?? Data()
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
                if resumed.testAndSet() {
                    continuation.resume(returning: Result(
                        status: finished.terminationStatus, stdout: stdout, stderr: stderr
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                cleanUp()
                if resumed.testAndSet() { continuation.resume(throwing: error) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Deliberately unconditional. A previous version bailed out when
                // the process had already exited, which meant that if anything
                // else went wrong the continuation was simply never resumed and
                // the caller hung forever. Resuming twice is impossible; not
                // resuming at all is fatal.
                if process.isRunning { process.terminate() }
                if resumed.testAndSet() {
                    cleanUp()
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
