#if os(iOS)
import Foundation
import UIKit
import os

/// Chunk transfers, routed to whichever session suits the moment.
///
/// The important property falls out of the protocol rather than this class: a
/// chunk that lands after iOS has terminated us is still recorded server-side,
/// so the next run's `probeUpload` comes back `.partial` with exactly the
/// chunks still missing. Nothing has to be replayed and nothing is lost.
///
/// While the app is *active* the transfer goes over an ordinary session. The
/// background session exists to survive suspension, and using it for work the
/// user is watching costs more than it gives: it runs out of process in
/// `nsurlsessiond`, is subject to system throttling, and — on the simulator
/// against a loopback address — fails outright with `NSURLErrorUnknown`, which
/// is how this was found. Foreground while you're looking, background when
/// you're not.
final class BackgroundTransfers: NSObject {
    static let shared = BackgroundTransfers()

    /// Set by the app delegate when iOS relaunches us to report finished
    /// transfers; calling it is how we tell the system we're done.
    ///
    /// Behind the lock like everything else here, and for the same reason: it
    /// is written on the main thread by the delegate and taken again on
    /// URLSession's delegate queue, which is two threads touching one mutable
    /// reference. `@Sendable` is doing real work on this type — the closure
    /// genuinely crosses isolation domains — so it stays.
    private var _systemCompletionHandler: (@Sendable () -> Void)?

    func setSystemCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _systemCompletionHandler = handler
    }

    /// Hands the handler over and forgets it, so it can only ever fire once.
    private func takeSystemCompletionHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let handler = _systemCompletionHandler
        _systemCompletionHandler = nil
        return handler
    }

    private let logger = Logger(subsystem: "com.michaelromero.FrameStation", category: "upload")
    private let lock = NSLock()

    /// A transfer, by the session that carries it as well as its number.
    ///
    /// A task identifier is only unique *within its session*, and there are two
    /// sessions — each numbers its tasks from one. Keyed on the number alone, a
    /// foreground chunk and a background chunk could share a slot: the second
    /// overwrote the first's continuation, which then never resumed, and the
    /// upload lane waiting on it waited for ever while the rest of the backup
    /// queued behind it. Caught on the simulator as "leaked its continuation"
    /// at the same instant two chunks both went out as task 1.
    private struct Key: Hashable {
        let session: ObjectIdentifier
        let task: Int

        init(_ session: URLSession, _ task: URLSessionTask) {
            self.session = ObjectIdentifier(session)
            self.task = task.taskIdentifier
        }
    }

    private var waiters: [Key: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var bodies: [Key: Data] = [:]
    /// Byte-progress reporters, keyed by task. iOS reports upload progress on
    /// the delegate, which is the only place it exists — there is no polling
    /// equivalent.
    private var reporters: [Key: @Sendable (Int64) -> Void] = [:]

    /// Made once, under the lock — see `foregroundSession`.
    private var _foregroundSession: URLSession?
    private var _backgroundSession: URLSession?

    /// Ordinary in-process session for foreground work.
    ///
    /// Behind the lock, not a `lazy var`. A lazy property is not safe to
    /// initialize from two threads at once, and the upload lanes reach for this
    /// concurrently: the first two chunks after launch each built a session of
    /// their own, both numbered their first task 1, and one lane lost its
    /// continuation. Two background sessions under one identifier would be
    /// worse still — iOS refuses the second outright.
    private var foregroundSession: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _foregroundSession { return existing }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        _foregroundSession = created
        return created
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _backgroundSession { return existing }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.michaelromero.FrameStation.upload"
        )
        // Not discretionary: the user asked for a backup, and letting iOS defer
        // it indefinitely is how "backup is stuck" bug reports happen. The
        // BGProcessingTask already gates on power and network.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        _backgroundSession = created
        return created
    }

    /// Starts the background session early so iOS can hand back any transfers
    /// that completed while we weren't running.
    func reconnect() { _ = session }

    /// Which session to hand this transfer to.
    ///
    /// The background one only once the app is actually in the background. A
    /// moment of `.inactive` — Control Center pulled down, a banner tapped, the
    /// app switcher — used to send that chunk out of process in the middle of a
    /// burst, for no gain: the app is still running and will be again in a
    /// second.
    private func transport() async -> URLSession {
        let background = await MainActor.run {
            UIApplication.shared.applicationState == .background
        }
        return background ? session : foregroundSession
    }

    /// Sends one chunk, waiting for it while the app is alive.
    ///
    /// If we're killed mid-flight the continuation dies with us and the upload
    /// still completes — the next probe reconciles. That's why this is safe to
    /// await rather than needing durable per-chunk bookkeeping.
    func upload(
        _ request: URLRequest,
        fromFile fileURL: URL,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> (Data, URLResponse) {
        let carrier = await transport()
        let task = carrier.uploadTask(with: request, fromFile: fileURL)
        let key = Key(carrier, task)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[key] = continuation
            reporters[key] = onProgress
            lock.unlock()
            task.resume()
        }
    }
}

extension BackgroundTransfers: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[Key(session, dataTask), default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let reporter = reporters[Key(session, task)]
        lock.unlock()
        reporter?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let key = Key(session, task)
        lock.lock()
        let waiter = waiters.removeValue(forKey: key)
        let body = bodies.removeValue(forKey: key) ?? Data()
        reporters.removeValue(forKey: key)
        lock.unlock()

        // No waiter means we were relaunched after this finished. Nothing to do:
        // the server has the chunk and the next probe will say so.
        guard let waiter else {
            if let error { logger.error("background chunk failed: \(error.localizedDescription)") }
            return
        }
        if let error {
            waiter.resume(throwing: error)
        } else if let response = task.response {
            waiter.resume(returning: (body, response))
        } else {
            waiter.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Must be called on the main thread, and must be called, or iOS
        // penalises the app's future background time.
        let handler = takeSystemCompletionHandler()
        DispatchQueue.main.async { handler?() }
    }
}
#endif
