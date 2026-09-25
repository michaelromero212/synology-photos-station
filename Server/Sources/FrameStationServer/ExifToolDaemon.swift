import Foundation
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One `exiftool` kept running for the request path, so reading a photo's
/// metadata at commit doesn't start Perl every time.
///
/// exiftool is a Perl program, and starting it — the interpreter, then its tag
/// tables — is most of the cost of reading one photo: about 40 ms on a Mac for
/// 10 ms of actual reading (see `MediaProbe.probePhotoBatch`), and a good deal
/// more on the NAS's Celeron. Every upload's commit waits on that read, because
/// it is what puts the photo on the right day. With `-stay_open`, one exiftool
/// takes command after command from its input and the start is paid once.
///
/// Built around the pipe hang recorded in `Shell.run`. Output goes to a regular
/// file that this polls, never to a pipe it waits on; only commands travel
/// through a pipe, a few hundred bytes each, and nothing here waits for that
/// pipe to close. A command that doesn't finish, or an exiftool that has gone,
/// throws — and `MediaProbe` runs exiftool the one-shot way, as it always did.
///
/// One command at a time, in order: exiftool reads its commands serially
/// anyway, and a queue here keeps each command's output apart from the next.
actor ExifToolDaemon {
    static let shared = ExifToolDaemon()

    enum Failure: Error {
        case unavailable
        case unsafeArgument
        case exited
        case timedOut
    }

    /// A new exiftool after this many commands. It bounds the output file, and
    /// whatever a Perl process left running for months might accumulate, for
    /// the price of one start in five hundred photos.
    private static let recycleAfter = 500

    private struct Running {
        let process: Process
        /// Where commands are written.
        let commands: FileHandle
        /// Read from as exiftool writes, never waited on.
        let output: FileHandle
        let outputURL: URL
    }

    /// A line when exiftool starts and when a command fails — every five
    /// hundred photos, and never, if all is well.
    private let logger = Logger(label: "exiftool")

    private var running: Running?
    private var served = 0
    private var sequence = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// Runs one exiftool command — the arguments exactly as they would follow
    /// `exiftool` on a command line — and returns what it printed.
    ///
    /// Not abandoned when the caller is cancelled: a command left half-read
    /// would have its output taken for the next one's. It runs to its end, or
    /// to `timeout`, where the whole process is thrown away instead.
    func run(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        // One argument per line is the protocol, so a line break inside one
        // would be read as two. Nothing sent here has one; refuse rather than
        // trust that.
        guard !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            throw Failure.unsafeArgument
        }
        await acquire()
        defer { release() }

        let current = try start()
        sequence += 1
        served += 1
        let marker = Data("{ready\(sequence)}\n".utf8)
        let command = (arguments + ["-execute\(sequence)"]).joined(separator: "\n") + "\n"
        do {
            try current.commands.write(contentsOf: Data(command.utf8))
        } catch {
            logger.warning("exiftool stopped taking commands: \(error)")
            discard()
            throw Failure.exited
        }

        let deadline = ContinuousClock.now + timeout
        var printed = Data()
        while true {
            if let more = try? current.output.readToEnd(), !more.isEmpty {
                printed.append(more)
                if let end = printed.range(of: marker) {
                    return Data(printed[..<end.lowerBound])
                }
            }
            guard current.process.isRunning else {
                logger.warning("exiftool exited mid-command")
                discard()
                throw Failure.exited
            }
            guard ContinuousClock.now < deadline else {
                logger.warning("exiftool took longer than \(timeout); starting another")
                discard()
                throw Failure.timedOut
            }
            try? await Task.sleep(for: .milliseconds(3))
        }
    }

    // MARK: - The process

    /// The running exiftool, starting one if there is none or the last has
    /// served its turn.
    private func start() throws -> Running {
        if let running, running.process.isRunning, served < Self.recycleAfter {
            return running
        }
        discard()
        _ = Self.ignoreBrokenPipes

        guard let executable = Shell.resolve("exiftool") else { throw Failure.unavailable }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("framestation-exiftool-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw Failure.unavailable
        }

        let writer: FileHandle
        let reader: FileHandle
        do {
            writer = try FileHandle(forWritingTo: outputURL)
            reader = try FileHandle(forReadingFrom: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw Failure.unavailable
        }

        let commands = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-stay_open", "True", "-@", "-"]
        process.standardInput = commands
        process.standardOutput = writer
        // Nothing reads it, so nothing can fill up waiting to be read. Failures
        // that matter show in the output, as a file with nothing to say.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? writer.close()
            try? reader.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw Failure.unavailable
        }
        // exiftool holds its own copies now. Ours of its ends go, so that
        // closing the command pipe on `discard` is an end of input it sees.
        try? writer.close()
        try? commands.fileHandleForReading.close()

        let started = Running(
            process: process,
            commands: commands.fileHandleForWriting,
            output: reader,
            outputURL: outputURL
        )
        running = started
        served = 0
        logger.info("exiftool running for metadata reads (pid \(process.processIdentifier))")
        return started
    }

    private func discard() {
        guard let running else { return }
        self.running = nil
        try? running.commands.close()
        if running.process.isRunning { running.process.terminate() }
        try? running.output.close()
        try? FileManager.default.removeItem(at: running.outputURL)
    }

    /// A command written to an exiftool that has just died would otherwise
    /// raise SIGPIPE, whose default is to end the process — the whole server,
    /// for one photo's metadata. Ignored, the write fails with an error instead,
    /// which `run` already handles. Standard for a server; set once.
    private static let ignoreBrokenPipes: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    // MARK: - One at a time

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }
}
