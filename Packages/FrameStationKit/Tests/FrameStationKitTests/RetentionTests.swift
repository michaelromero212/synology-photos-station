import Foundation
import Testing

@testable import FrameStationAPI

@Suite("Recently Deleted counts down honestly")
struct RetentionTests {
    private func item(purgeAt: Date?) -> TimelineItem {
        TimelineItem(
            id: UUID(), spaceID: UUID(), assetID: UUID(),
            capturedAt: Date(), aspectRatio: 1, mediaType: .photo,
            durationMs: nil, thumbHash: nil, isFavorite: false,
            uploadedBy: UUID(), isDerived: true, purgeAt: purgeAt
        )
    }

    /// The number on the tile on the day you press delete.
    ///
    /// Rounding down would say 28 twenty minutes after a deletion, which
    /// contradicts the sentence at the top of the same screen promising 29.
    @Test("A photo deleted moments ago still shows the full window")
    func fullWindowOnTheDayOfDeletion() {
        let deleted = Date().addingTimeInterval(-20 * 60)
        let purge = deleted.addingTimeInterval(Double(Retention.days) * 86_400)
        #expect(item(purgeAt: purge).daysUntilPurge == Retention.days)
    }

    @Test("The last day reads as one day, not zero")
    func lastDay() {
        let purge = Date().addingTimeInterval(20 * 3600)
        #expect(item(purgeAt: purge).daysUntilPurge == 1)
    }

    /// The sweeper runs hourly, so a photo can sit a little past its window
    /// before the purge catches it. It must not display a negative countdown in
    /// that gap.
    @Test("Past the window floors at zero rather than going negative")
    func pastTheWindow() {
        let purge = Date().addingTimeInterval(-3 * 86_400)
        #expect(item(purgeAt: purge).daysUntilPurge == 0)
    }

    /// Everything outside Recently Deleted has no clock, and the badge keys off
    /// exactly this being nil.
    @Test("An ordinary photo has no countdown at all")
    func noCountdownForLivePhotos() {
        #expect(item(purgeAt: nil).daysUntilPurge == nil)
    }

    /// `purgeAt` crosses the wire; a rename or a missed decode would silently
    /// drop every badge on the screen.
    @Test("purgeAt survives a round trip")
    func roundTrip() throws {
        let purge = Date().addingTimeInterval(10 * 86_400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(item(purgeAt: purge))
        let decoded = try decoder.decode(TimelineItem.self, from: data)
        #expect(decoded.purgeAt != nil)
        #expect(decoded.daysUntilPurge == 10)
    }
}
