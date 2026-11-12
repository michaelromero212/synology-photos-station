#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// Asks iOS to wake us up to keep backing up.
///
/// Two requests, because iOS grants them on different terms. A
/// `BGProcessingTask` gets minutes and can require power, which is what a
/// backlog needs; iOS runs it rarely, typically overnight on charge, and no
/// amount of asking changes that. A `BGAppRefreshTask` gets about half a
/// minute, far more often, through the day: enough to notice the photos taken
/// since the app was last open, send the small ones, and hand the rest to the
/// background session. Both run the same wake-up.
///
/// The refresh was permitted in Info.plist from the start and never asked for,
/// so a phone that wasn't opened had only the overnight window to rely on.
enum BackupScheduler {
    static let taskIdentifier = "com.michaelromero.FrameStation.backup"
    static let refreshIdentifier = "com.michaelromero.FrameStation.refresh"
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
    ///
    /// `run` books the next window itself, first thing (`BackupRuntime.wake`),
    /// not when it's done: a window that ran out, or a wake-up that found the
    /// phone signed out, used to end without booking another, and background
    /// backup then stopped until someone opened the app.
    ///
    /// `run` is told which window it is, for the diagnostics log: the only
    /// record there is of a wake-up nobody was there to see.
    static func register(run: @escaping @Sendable (_ window: String) async -> Void) {
        for identifier in [taskIdentifier, refreshIdentifier] {
            let window = identifier == taskIdentifier ? "long" : "short"
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                // Said once, by whichever comes first: the run ending or the
                // window. Telling iOS twice is a programmer error it traps on.
                let finished = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Bool) -> Void = { success in
                    let first = finished.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    if first { task.setTaskCompleted(success: success) }
                }
                Task {
                    await run(window)
                    finish(true)
                }
                // Out of time. iOS has to be answered now: an app that doesn't
                // is ended rather than suspended, and that used to happen on
                // any backlog longer than one window, because the answer waited
                // for the run. The run itself is left going, as a silent push
                // leaves it: what's mid-chunk finishes in the background
                // session, and the next wake-up joins the run where it stands
                // or, if iOS ended the app after all, resumes from the chunks
                // the NAS kept.
                task.expirationHandler = {
                    logger.notice("background backup window ended — the next one carries on")
                    finish(false)
                    Task { @MainActor in
                        Diagnostics.shared.log(
                            .backup, "iOS ended the \(window) background window before the backup finished"
                        )
                    }
                }
            }
        }
    }

    /// Requests another window of each kind. Safe to call repeatedly; a
    /// pending request is simply replaced.
    static func schedule(requiresPower: Bool) {
        let processing = BGProcessingTaskRequest(identifier: taskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = requiresPower
        // Not a promise of when — only the earliest iOS will consider us.
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(processing)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(refresh)
    }

    private static func submit(_ request: BGTaskRequest) {
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
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
    }
}
#endif
