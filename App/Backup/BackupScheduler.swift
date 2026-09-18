#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// Asks iOS to wake us up to keep backing up.
///
/// `BGProcessingTask` rather than `BGAppRefreshTask`: refresh tasks get seconds,
/// processing tasks get minutes and can require power — which is what a photo
/// backup actually needs. iOS decides when, typically overnight on charge, and
/// no amount of asking changes that.
enum BackupScheduler {
    static let taskIdentifier = "com.michaelromero.FrameStation.backup"
    private static let logger = Logger(
        subsystem: "com.michaelromero.FrameStation", category: "scheduler"
    )

    /// Must be called before the app finishes launching, or iOS throws.
    ///
    /// `run` is awaited to completion before the task is reported finished, and
    /// that is load-bearing. It used to hand back a closure that merely *started*
    /// the backup, so `setTaskCompleted` fired within milliseconds — iOS was told
    /// the window had been used while nothing had been sent, and was free to
    /// suspend us mid-upload. Every window was thrown away and the record showed
    /// a long line of successful background runs.
    static func register(run: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            let work = Task {
                await run()
                task.setTaskCompleted(success: true)
            }
            // iOS gives no warning before it pulls the plug; cancelling cleanly
            // means the queue is left consistent for the next wake-up.
            task.expirationHandler = {
                logger.notice("background backup expired — will resume next window")
                work.cancel()
            }
        }
    }

    /// Requests another window. Safe to call repeatedly; a pending request is
    /// simply replaced.
    static func schedule(requiresPower: Bool) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = requiresPower
        // Not a promise of when — only the earliest iOS will consider us.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulators refuse to schedule these at all, which is expected and
            // not worth surfacing to the user.
            logger.info("couldn't schedule background backup: \(error.localizedDescription)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}
#endif
