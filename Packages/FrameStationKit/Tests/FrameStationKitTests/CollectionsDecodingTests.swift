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

    // MARK: - Over the Years

    private func tradition(_ id: String, _ title: String, years: [String]) -> String {
        """
        {"id":"\(id)","title":"\(title)","subtitle":"2 years · 2024–2025","count":12,\
        "coverAssetIDs":[],"years":[\(years.joined(separator: ","))],"next":"2026-12-24"}
        """
    }

    /// A server from before Over the Years sends no such field, and the page
    /// draws no section rather than an empty one.
    func testAnOlderServerHasNoTraditions() throws {
        let page = try decode("""
            {"trips":[],"days":[\(card("day", "2025-12-25", "Christmas 2025"))],"revisits":[],"mediaTypes":[]}
            """)

        XCTAssertNil(page.traditions)
        XCTAssertEqual(page.days.map(\.title), ["Christmas 2025"])
    }

    /// A year of a kind this build can't read costs that year, not the
    /// tradition, and a tradition that can't be read costs only itself.
    func testTraditionsAreReadOneByOne() throws {
        let page = try decode("""
            {"trips":[],"days":[],"revisits":[],"mediaTypes":[],
             "traditions":[\(tradition("holiday:Christmas", "Christmas", years: [
                card("someFutureKind", "x", "Christmas 2025"),
                card("day", "2024-12-25", "Christmas 2024"),
             ])),
             {"title":"No id"},
             \(tradition("date:04-05", "Birthday on April 5", years: [card("day", "2025-04-05", "April 5, 2025")]))]}
            """)

        XCTAssertEqual(page.traditions?.map(\.id), ["holiday:Christmas", "date:04-05"])
        XCTAssertEqual(page.traditions?.first?.years.map(\.title), ["Christmas 2024"])
        XCTAssertEqual(page.traditions?.first?.next, "2026-12-24")
        XCTAssertNil(page.traditions?.first?.naming)
    }

    /// The Mac's fuller rows: absent from an older server, read card by card
    /// from a newer one.
    func testWideRows() throws {
        let older = try decode("""
            {"trips":[\(card("trip", "2026-07-18", "Seven days in Duck"))],"days":[],"revisits":[],"mediaTypes":[]}
            """)
        XCTAssertNil(older.wideTrips)
        XCTAssertNil(older.wideDays)

        let newer = try decode("""
            {"trips":[],"days":[],"revisits":[],"mediaTypes":[],
             "wideTrips":[\(card("trip", "2026-07-18", "Seven days in Duck")),
                          \(card("someFutureKind", "x", "Somewhere"))],
             "wideDays":[\(card("day", "2025-12-25", "Christmas 2025"))]}
            """)
        XCTAssertEqual(newer.wideTrips?.map(\.title), ["Seven days in Duck"])
        XCTAssertEqual(newer.wideDays?.map(\.title), ["Christmas 2025"])
    }

    /// With Over the Years on the page, Holidays & Occasions is what happened
    /// once; from an older server it's everything, as it always was.
    func testOccasionsLeaveTheYearsOfATraditionToIt() throws {
        let christmas = """
            {"kind":"day","key":"2024-12-25","title":"Christmas 2024","count":12,"coverAssetIDs":[],\
            "isNamed":false,"recursAnnually":false,"tradition":"holiday:Christmas"}
            """
        let graduation = card("day", "2024-05-18", "Graduation in Harrisonburg")
        let newer = try decode("""
            {"trips":[],"days":[\(christmas),\(graduation)],"revisits":[],"mediaTypes":[],
             "allOccasions":[\(christmas),\(graduation)],"traditions":[],
             "wideDays":[\(graduation)]}
            """)
        XCTAssertEqual(newer.allOccasions?.first?.tradition, "holiday:Christmas")
        XCTAssertEqual(newer.onceOccasions?.map(\.title), ["Graduation in Harrisonburg"])
        XCTAssertEqual(newer.onceDays(limit: 3).map(\.title), ["Graduation in Harrisonburg"])

        let older = try decode("""
            {"trips":[],"days":[\(christmas),\(graduation)],"revisits":[],"mediaTypes":[],
             "allOccasions":[\(christmas),\(graduation)]}
            """)
        XCTAssertEqual(older.onceOccasions?.count, 2)
        XCTAssertEqual(older.onceDays(limit: 3).count, 2)
    }

    func testTraditionsRoundTrip() throws {
        let year = CollectionSummary(
            kind: .day, key: "2025-04-05", title: "April 5, 2025", subtitle: "Saturday",
            count: 10, coverAssetIDs: [UUID()], recursAnnually: true
        )
        let original = CollectionsResponse(
            hero: nil, trips: [], days: [], recentlyDeleted: nil,
            traditions: [Tradition(
                id: "date:04-05", title: "Birthday on April 5", subtitle: "7 years · 2019–2025",
                count: 64, coverAssetIDs: [UUID()], years: [year], next: "2027-04-05",
                naming: year
            )]
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(CollectionsResponse.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
