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

    @Test("Scan-all doesn't promise to bring back what you deleted")
    func scanAllKeepsDeletionsDeleted() {
        #expect(BackupRule.scanAll.detail.contains("stay deleted"))
        #expect(!BackupRule.scanAll.detail.contains("backed up again"))
    }
}

@Suite("What's already queued follows the settings too")
struct BackupScopeTests {
    private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    private var before: Date { cutoff.addingTimeInterval(-3600) }
    private var after: Date { cutoff.addingTimeInterval(3600) }

    @Test("Photos Only holds back every video, edits and Live Photo motion included")
    func photosOnlyHoldsVideos() {
        let scope = BackupScope(includeVideos: false, rule: .resume, cutoff: nil)
        #expect(!scope.includes(isVideo: true, takenAt: after))
        #expect(!scope.includes(isVideo: true, takenAt: after, isEdit: true))
        #expect(scope.includes(isVideo: false, takenAt: before))
    }

    @Test("Future-only holds back older photos, but not later edits of ones already sent")
    func futureOnlyHoldsThePastButNotEdits() {
        let scope = BackupScope(includeVideos: true, rule: .futureOnly, cutoff: cutoff)
        #expect(!scope.includes(isVideo: false, takenAt: before))
        #expect(scope.includes(isVideo: false, takenAt: after))
        #expect(scope.includes(isVideo: false, takenAt: before, isEdit: true))
        #expect(scope.includes(isVideo: false, takenAt: nil))
    }

    @Test("With nothing excluded, everything queued goes")
    func defaultsSendEverything() {
        let scope = BackupScope(includeVideos: true, rule: .resume, cutoff: nil)
        #expect(scope.includes(isVideo: true, takenAt: before))
        #expect(scope.includes(isVideo: false, takenAt: nil))
    }
}
