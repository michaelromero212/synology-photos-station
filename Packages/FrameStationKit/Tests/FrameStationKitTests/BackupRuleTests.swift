import Foundation
import Testing
@testable import FrameStationKit

@Suite("Backup rules decide what a scan covers")
struct BackupRuleTests {
    private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    private var before: Date { cutoff.addingTimeInterval(-3600) }
    private var after: Date { cutoff.addingTimeInterval(3600) }

    @Test("Resume and scan-all queue regardless of when a photo was taken")
    func sweepingRulesIgnoreDates() {
        for rule in [BackupRule.resume, .scanAll] {
            #expect(rule.queues(takenAt: before, cutoff: cutoff))
            #expect(rule.queues(takenAt: after, cutoff: cutoff))
            #expect(rule.queues(takenAt: nil, cutoff: cutoff))
        }
    }

    @Test("Future-only excludes everything taken before the line")
    func futureOnlyExcludesThePast() {
        #expect(BackupRule.futureOnly.queues(takenAt: after, cutoff: cutoff))
        #expect(!BackupRule.futureOnly.queues(takenAt: before, cutoff: cutoff))
    }

    @Test("A photo taken exactly at the cutoff is taken, not dropped")
    func cutoffIsInclusive() {
        #expect(BackupRule.futureOnly.queues(takenAt: cutoff, cutoff: cutoff))
    }

    @Test("Future-only with no line drawn holds nothing back")
    func futureOnlyWithoutCutoffQueuesEverything() {
        #expect(BackupRule.futureOnly.queues(takenAt: before, cutoff: nil))
    }

    @Test("An undated photo is taken rather than silently dropped")
    func undatedPhotosAreQueued() {
        #expect(BackupRule.futureOnly.queues(takenAt: nil, cutoff: cutoff))
    }

    @Test("Only scan-all gives failed and skipped items another attempt")
    func onlyScanAllRetries() {
        #expect(BackupRule.scanAll.retriesPreviousFailures)
        #expect(!BackupRule.resume.retriesPreviousFailures)
        #expect(!BackupRule.futureOnly.retriesPreviousFailures)
    }
}
