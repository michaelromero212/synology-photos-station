import Foundation

/// When a file iOS couldn't send in the background is given another go.
///
/// iOS retries a failed upload once and then lets it go. That was the end of it
/// for the background upload extension too: the file waited for the app to be
/// opened, so a NAS that was down for a day left a day of photos behind on a
/// phone nobody had touched. The extension now queues such a file again on its
/// later runs, and this is how often and for how long.
///
/// Spaced out, because a run is no sign the trouble has passed: iOS runs the
/// extension when a photo is taken, and someone taking twenty photos in an
/// outage shouldn't send each earlier one twenty times. Bounded, because a file
/// that fails every time is one the app's own upload has to deal with: it sends
/// in pieces and picks up where it stopped, which a background job can't.
public enum BackgroundRetry {
    /// How many times a file may fail before the extension leaves it to the
    /// app.
    public static let limit = 10
    /// How long after its first failure, at most.
    public static let lifetime: TimeInterval = 7 * 86_400

    static let firstWait: TimeInterval = 15 * 60
    static let longestWait: TimeInterval = 12 * 3600

    /// How long to leave a file alone once it has failed `failures` times: a
    /// quarter of an hour, doubling, up to half a day. Together the waits
    /// outlast an outage of two days.
    public static func wait(afterFailures failures: Int) -> TimeInterval {
        let doublings = min(max(failures, 1) - 1, 16)
        return min(firstWait * pow(2, Double(doublings)), longestWait)
    }

    /// Whether the extension has done all it will for a file.
    public static func isSpent(failures: Int, firstFailedAt: Date, now: Date) -> Bool {
        failures >= limit || now.timeIntervalSince(firstFailedAt) > lifetime
    }

    /// Whether it's time to queue a file again.
    public static func isDue(
        failures: Int, firstFailedAt: Date, lastFailedAt: Date, now: Date
    ) -> Bool {
        !isSpent(failures: failures, firstFailedAt: firstFailedAt, now: now)
            && now.timeIntervalSince(lastFailedAt) >= wait(afterFailures: failures)
    }
}
