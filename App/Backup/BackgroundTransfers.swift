#if os(iOS)
import Foundation
import os

/// Chunk transfers that outlive the app being suspended or killed.
///
/// The important property falls out of the protocol rather than this class: a
/// chunk that lands after iOS has terminated us is still recorded server-side,
/// so the next run's `probeUpload` comes back `.partial` with exactly the
/// chunks still missing. Nothing has to be replayed and nothing is lost — this
/// only has to hand iOS the work and get out of the way.
final class BackgroundTransfers: NSObject {
    static let shared = BackgroundTransfers()

    /// Set by the app delegate when iOS relaunches us to report finished
    /// transfers; calling it is how we tell the system we're done.
    var systemCompletionHandler: (@Sendable () -> Void)?

    private let logger = Logger(subsystem: "com.michaelromero.FrameStation", category: "upload")
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var bodies: [Int: Data] = [:]
    /// Byte-progress reporters, keyed by task. iOS reports upload progress on
    /// the delegate, which is the only place it exists — there is no polling
    /// equivalent.
    private var reporters: [Int: @Sendable (Int64) -> Void] = [:]

    private lazy var session: URLSession = {
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
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Starts the session early so iOS can hand back any transfers that
    /// completed while we weren't running.
    func reconnect() { _ = session }

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
        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[task.taskIdentifier] = continuation
            reporters[task.taskIdentifier] = onProgress
            lock.unlock()
            task.resume()
        }
    }
}

extension BackgroundTransfers: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
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
        let reporter = reporters[task.taskIdentifier]
        lock.unlock()
        reporter?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        reporters.removeValue(forKey: task.taskIdentifier)
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
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }
}
#endif
