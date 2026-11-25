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
                count: 7, coverAssetIDs: [UUID(), UUID()], coverVersions: [5, 3], isNamed: true,
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
            count: 10, coverAssetIDs: [UUID()], coverVersions: [4], recursAnnually: true
        )
        let original = CollectionsResponse(
            hero: nil, trips: [], days: [], recentlyDeleted: nil,
            traditions: [Tradition(
                id: "date:04-05", title: "Birthday on April 5", subtitle: "7 years · 2019–2025",
                count: 64, coverAssetIDs: [UUID()], coverVersions: [5], years: [year],
                next: "2027-04-05", naming: year
            )]
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(CollectionsResponse.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Cover versions
    //
    // A cover is fetched at its thumbnail's version, which is in the URL and
    // the cache key, so a cover the NAS makes again is fetched fresh instead
    // of kept from the cache forever.

    private let first = UUID(uuidString: "9A4C4021-1DE7-428C-BE59-5D8EA41C7101")!
    private let second = UUID(uuidString: "9A4C4021-1DE7-428C-BE59-5D8EA41C7102")!

    private func trip(versions: String?) -> String {
        """
        {"kind":"trip","key":"2026-07-18","title":"Seven days in Duck","count":12,\
        "coverAssetIDs":["\(first)","\(second)"],\(versions.map { "\"coverVersions\":\($0)," } ?? "")\
        "isNamed":false,"recursAnnually":false}
        """
    }

    private func christmas(versions: String?) -> String {
        """
        {"id":"holiday:Christmas","title":"Christmas","count":12,"coverAssetIDs":["\(first)"],\
        \(versions.map { "\"coverVersions\":\($0)," } ?? "")"years":[\(trip(versions: versions == nil ? nil : "[6,7]"))]}
        """
    }

    /// From a server before cover versions, every cover is version 0: what
    /// the app asked for before, so nothing it has cached is lost.
    func testCoversFromAnOlderServerAreVersionZero() throws {
        let page = try decode("""
            {"trips":[\(trip(versions: nil))],"days":[],"revisits":[],"mediaTypes":[],
             "traditions":[\(christmas(versions: nil))]}
            """)

        let trip = try XCTUnwrap(page.trips.first)
        XCTAssertNil(trip.coverVersions)
        XCTAssertEqual(trip.covers, [CoverThumbnail(assetID: first), CoverThumbnail(assetID: second)])
        let christmas = try XCTUnwrap(page.traditions?.first)
        XCTAssertNil(christmas.coverVersions)
        XCTAssertEqual(christmas.covers, [CoverThumbnail(assetID: first, version: 0)])
        XCTAssertEqual(christmas.years.first?.covers.map(\.version), [0, 0])
    }

    /// From a newer one, each cover's version is beside it, index for index.
    func testCoverVersionsTravelBesideTheirCovers() throws {
        let page = try decode("""
            {"trips":[\(trip(versions: "[5,3]"))],"days":[],"revisits":[],"mediaTypes":[],
             "traditions":[\(christmas(versions: "[5]"))]}
            """)

        XCTAssertEqual(page.trips.first?.covers, [
            CoverThumbnail(assetID: first, version: 5), CoverThumbnail(assetID: second, version: 3),
        ])
        XCTAssertEqual(page.traditions?.first?.covers, [CoverThumbnail(assetID: first, version: 5)])
        XCTAssertEqual(page.traditions?.first?.years.first?.covers.map(\.version), [6, 7])
    }

    /// Fewer versions than covers, which no server sends, still read index
    /// for index, with 0 past their end.
    func testVersionsShortOfTheCoversReadAsZeroPastTheirEnd() {
        let card = CollectionSummary(
            kind: .trip, key: "2026-07-18", title: "Seven days in Duck", subtitle: nil,
            count: 12, coverAssetIDs: [first, second], coverVersions: [7]
        )
        XCTAssertEqual(card.covers.map(\.version), [7, 0])
    }

    /// The server fills them in one lookup for the whole page, so every card
    /// has to be reached: each section's, each tradition, its years and its
    /// naming card. The People row's faces are pictures of their own, and
    /// nothing else on the page changes.
    func testEveryCoverOnThePageGetsItsVersion() throws {
        var made = 0
        func card(_ kind: CollectionKind) -> CollectionSummary {
            made += 1
            return CollectionSummary(
                kind: kind, key: "key-\(made)", title: "Card \(made)", subtitle: nil,
                count: 12, coverAssetIDs: [UUID(), UUID()]
            )
        }
        let tradition = Tradition(
            id: "holiday:Christmas", title: "Christmas", subtitle: nil, count: 24,
            coverAssetIDs: [UUID()], years: [card(.day), card(.day)], naming: card(.day)
        )
        let person = PersonSummary(id: UUID(), name: "Emma", photoCount: 40, face: "face-1")
        let page = CollectionsResponse(
            hero: card(.onThisDay), trips: [card(.trip)], days: [card(.day)],
            revisits: [card(.revisit)], mediaTypes: [card(.mediaType)],
            recentlyDeleted: card(.recentlyDeleted), recentlyAdded: card(.recentlyAdded),
            favorites: card(.favorites), allTrips: [card(.trip)], allOccasions: [card(.day)],
            featured: [card(.trip)], traditions: [tradition], wideTrips: [card(.trip)],
            wideDays: [card(.day)], people: [person]
        )

        // Thirteen cards across the sections and three in the tradition, two
        // covers each, and the tradition's own.
        let assetIDs = page.allCoverAssetIDs
        XCTAssertEqual(assetIDs.count, 16 * 2 + 1)
        // Every version different, so a cover given its neighbor's shows.
        let versions = Dictionary(uniqueKeysWithValues: assetIDs.enumerated().map { ($1, $0 + 1) })
        let filled = page.withCoverVersions(versions)

        func cards(_ page: CollectionsResponse) -> [CollectionSummary] {
            [page.hero, page.recentlyDeleted, page.recentlyAdded, page.favorites].compactMap { $0 }
                + page.trips + page.days + page.revisits + page.mediaTypes
                + (page.allTrips ?? []) + (page.allOccasions ?? []) + (page.featured ?? [])
                + (page.wideTrips ?? []) + (page.wideDays ?? [])
                + (page.traditions ?? []).flatMap { $0.years + [$0.naming].compactMap { $0 } }
        }
        let before = cards(page), after = cards(filled)
        XCTAssertEqual(after.count, 16)
        for (card, was) in zip(after, before) {
            XCTAssertEqual(card.coverVersions, card.coverAssetIDs.map { versions[$0] ?? -1 }, card.title)
            XCTAssertEqual(card.withCovers(card.coverAssetIDs, versions: nil), was, card.title)
        }
        let christmas = try XCTUnwrap(filled.traditions?.first)
        XCTAssertEqual(christmas.coverVersions, tradition.coverAssetIDs.map { versions[$0] ?? -1 })
        XCTAssertEqual(filled.people, [person])

        // A cover the lookup found no row for reads as 0.
        XCTAssertEqual(page.withCoverVersions([:]).trips.first?.coverVersions, [0, 0])
    }

    /// A card changed for the page keeps its versions, and one put under
    /// other covers takes theirs: a held cover keeps the version it was drawn
    /// at, whatever the new answer says.
    func testVersionsStayWithTheirCovers() {
        let card = CollectionSummary(
            kind: .day, key: "2025-12-25", title: "Christmas 2025", subtitle: nil,
            count: 12, coverAssetIDs: [first, second], coverVersions: [5, 3]
        )
        XCTAssertEqual(card.withKicker("CHRISTMAS IS COMING UP").coverVersions, [5, 3])
        XCTAssertEqual(card.withTitle("Deem Christmas 2025").coverVersions, [5, 3])
        XCTAssertEqual(card.withSubtitle("With Emma").coverVersions, [5, 3])
        XCTAssertEqual(card.inTradition("holiday:Christmas").coverVersions, [5, 3])

        let drawn = UUID()
        let held = card.withCovers([drawn], versions: [4])
        XCTAssertEqual(held.covers, [CoverThumbnail(assetID: drawn, version: 4)])
        XCTAssertEqual(held.title, card.title)
        XCTAssertEqual(card.withCovers(card.coverAssetIDs, versions: card.coverVersions), card)
    }
}
