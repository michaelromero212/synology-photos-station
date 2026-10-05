import FrameStationAPI
import XCTest

/// The Albums page has to survive a server that knows more kinds than the app.
///
/// `CollectionSummary.kind` is a closed set. Before `CollectionsResponse`
/// decoded card by card, one card of a kind the app had never heard of failed
/// the whole response — the hero and every shelf — on any device still running
/// an older build. Curated albums are about to add kinds.
final class CollectionsDecodingTests: XCTestCase {
    private func card(_ kind: String, _ key: String, _ title: String) -> String {
        """
        {"kind":"\(kind)","key":"\(key)","title":"\(title)","count":12,\
        "coverAssetIDs":[],"isNamed":false,"recursAnnually":false}
        """
    }

    private func decode(_ json: String) throws -> CollectionsResponse {
        try FrameStationCoding.decoder.decode(CollectionsResponse.self, from: Data(json.utf8))
    }

    func testAnUnknownKindCostsOneCardNotThePage() throws {
        let page = try decode("""
            {"hero":\(card("onThisDay", "2025", "One year ago")),
             "trips":[\(card("trip", "2026-07-18", "Seven days in Duck"))],
             "days":[\(card("someFutureKind", "x", "Birthday Party")),
                     \(card("day", "2025-12-25", "Christmas"))],
             "revisits":[],"mediaTypes":[]}
            """)

        XCTAssertEqual(page.hero?.kind, .onThisDay)
        XCTAssertEqual(page.trips.map(\.title), ["Seven days in Duck"])
        XCTAssertEqual(page.days.map(\.title), ["Christmas"])
    }

    func testAnUnknownHeroLeavesTheShelves() throws {
        let page = try decode("""
            {"hero":\(card("someFutureKind", "x", "Birthday Party")),
             "trips":[\(card("trip", "2026-07-18", "Seven days in Duck"))],
             "days":[],"revisits":[],"mediaTypes":[],
             "favourites":\(card("favourites", "all", "Favorites"))}
            """)

        XCTAssertNil(page.hero)
        XCTAssertEqual(page.trips.count, 1)
        XCTAssertEqual(page.favorites?.kind, .favorites)
    }

    func testUnknownKindsInSeeAllAreDropped() throws {
        let page = try decode("""
            {"trips":[],"days":[],"revisits":[],"mediaTypes":[],
             "allOccasions":[\(card("someFutureKind", "x", "Concert")),
                             \(card("day", "2025-07-04", "Fourth of July"))]}
            """)

        XCTAssertEqual(page.allOccasions?.map(\.title), ["Fourth of July"])
        XCTAssertNil(page.allTrips)
    }

    func testMissingArraysReadAsEmpty() throws {
        let page = try decode("""
            {"hero":\(card("season", "2026-summer", "Last summer"))}
            """)

        XCTAssertEqual(page.hero?.title, "Last summer")
        XCTAssertTrue(page.trips.isEmpty)
        XCTAssertTrue(page.days.isEmpty)
        XCTAssertTrue(page.revisits.isEmpty)
        XCTAssertTrue(page.mediaTypes.isEmpty)
    }

    /// Nothing a current server sends is changed by any of the above.
    func testAFullPageRoundTripsUnchanged() throws {
        func summary(_ kind: CollectionKind, _ key: String) -> CollectionSummary {
            CollectionSummary(
                kind: kind, key: key, title: "Title \(key)", subtitle: "Subtitle",
                count: 7, coverAssetIDs: [UUID(), UUID()], isNamed: true,
                recursAnnually: true, kicker: "COMING UP"
            )
        }
        let original = CollectionsResponse(
            hero: summary(.onThisDay, "2025"),
            trips: [summary(.trip, "2026-07-18")],
            days: [summary(.day, "2025-12-25")],
            revisits: [summary(.revisit, "Duck")],
            mediaTypes: [summary(.mediaType, "videos")],
            recentlyDeleted: summary(.recentlyDeleted, "all"),
            recentlyAdded: summary(.recentlyAdded, "all"),
            favorites: summary(.favorites, "all"),
            allTrips: [summary(.trip, "2026-07-18"), summary(.trip, "2025-06-01")],
            allOccasions: [summary(.day, "2025-12-25")]
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(CollectionsResponse.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("\"favourites\""),
            "Favorites must keep the key it shipped as"
        )
    }
}
