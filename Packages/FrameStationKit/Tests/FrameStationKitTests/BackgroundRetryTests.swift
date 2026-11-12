import Foundation
import Testing
@testable import FrameStationKit

@Suite("Background retries are spaced out and bounded")
struct BackgroundRetryTests {
    private let first = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600

    @Test("The waits start at 15 minutes and double each time")
    func waitsDouble() {
        #expect(BackgroundRetry.wait(afterFailures: 1) == 15 * minute)
        #expect(BackgroundRetry.wait(afterFailures: 2) == 30 * minute)
        #expect(BackgroundRetry.wait(afterFailures: 3) == 1 * hour)
        #expect(BackgroundRetry.wait(afterFailures: 4) == 2 * hour)
        #expect(BackgroundRetry.wait(afterFailures: 5) == 4 * hour)
        #expect(BackgroundRetry.wait(afterFailures: 6) == 8 * hour)
    }

    @Test("From the seventh failure on, the wait stays at 12 hours")
    func waitsAreCapped() {
        for failures in 7...20 {
            #expect(BackgroundRetry.wait(afterFailures: failures) == 12 * hour)
        }
    }

    @Test("Zero or negative failures are treated like the first")
    func nonPositiveCountsActLikeOne() {
        for failures in [0, -1, -50, Int.min] {
            #expect(BackgroundRetry.wait(afterFailures: failures) == 15 * minute)
        }
    }

    @Test("A huge failure count doesn't overflow or pass the cap")
    func hugeCountsStayCapped() {
        for failures in [1_000, Int.max] {
            let wait = BackgroundRetry.wait(afterFailures: failures)
            #expect(wait == 12 * hour)
            #expect(wait.isFinite)
        }
    }

    @Test("The waits before the limit add up to more than two days")
    func waitsOutlastAnOutage() {
        let total = (1..<BackgroundRetry.limit)
            .map { BackgroundRetry.wait(afterFailures: $0) }
            .reduce(0, +)
        #expect(total > 48 * hour)
    }

    @Test("A file isn't due one second before its wait is up, and is due at it")
    func dueExactlyWhenTheWaitIsUp() {
        let failures = 3
        let wait = BackgroundRetry.wait(afterFailures: failures)
        let last = first.addingTimeInterval(2 * hour)
        #expect(!BackgroundRetry.isDue(
            failures: failures, firstFailedAt: first, lastFailedAt: last,
            now: last.addingTimeInterval(wait - 1)))
        #expect(BackgroundRetry.isDue(
            failures: failures, firstFailedAt: first, lastFailedAt: last,
            now: last.addingTimeInterval(wait)))
    }

    @Test("A file is spent at the failure limit, not one before")
    func spentAtTheLimit() {
        let now = first.addingTimeInterval(hour)
        #expect(BackgroundRetry.isSpent(
            failures: BackgroundRetry.limit, firstFailedAt: first, now: now))
        #expect(!BackgroundRetry.isSpent(
            failures: BackgroundRetry.limit - 1, firstFailedAt: first, now: now))
    }

    @Test("A file is spent once its lifetime has passed, not before")
    func spentPastTheLifetime() {
        let failures = 1
        #expect(!BackgroundRetry.isSpent(
            failures: failures, firstFailedAt: first,
            now: first.addingTimeInterval(BackgroundRetry.lifetime - 1)))
        #expect(!BackgroundRetry.isSpent(
            failures: failures, firstFailedAt: first,
            now: first.addingTimeInterval(BackgroundRetry.lifetime)))
        #expect(BackgroundRetry.isSpent(
            failures: failures, firstFailedAt: first,
            now: first.addingTimeInterval(BackgroundRetry.lifetime + 1)))
    }

    @Test("A spent file is never due, even when its wait is long over")
    func spentFilesAreNeverDue() {
        let last = first.addingTimeInterval(hour)
        let wayLater = last.addingTimeInterval(100 * hour)
        // Out of failures.
        #expect(!BackgroundRetry.isDue(
            failures: BackgroundRetry.limit, firstFailedAt: first,
            lastFailedAt: last, now: wayLater))
        // Out of time.
        let old = first.addingTimeInterval(BackgroundRetry.lifetime + 1)
        #expect(!BackgroundRetry.isDue(
            failures: 2, firstFailedAt: first,
            lastFailedAt: first.addingTimeInterval(hour), now: old))
    }
}
