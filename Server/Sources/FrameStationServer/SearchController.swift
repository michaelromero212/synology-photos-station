import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension PlacesResponse: @retroactive Content {}
extension SearchResults: @retroactive Content {}

/// Search, v1: where a photo was taken.
///
/// Deliberately narrow. `place_name` is filled in at import by the offline
/// geocoder, so this searches a column the library already has for every photo
/// with GPS — no new index to build, no ML runtime, and nothing leaves the NAS.
/// Tags are the obvious next axis and are not here yet, because the importer
/// discards IPTC keywords and a tag search would open on an empty vocabulary.
struct SearchController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("spaces", ":spaceID", "places", use: places)
        protected.get("spaces", ":spaceID", "search", use: search)
    }

    // MARK: - Places

    private struct PlaceRow: Decodable {
        let name: String
        let count: Int
    }

    /// The places this space has photos from, commonest first.
    ///
    /// Commonest rather than alphabetical because the top of this list is the
    /// screen you land on before typing anything: it should open on where the
    /// family actually lives and holidays, not wherever happens to start with A.
    ///
    /// Bounded, and that matters more than it sounds. A library accumulates one
    /// row per town anyone ever drove through, so ordering by count produces a
    /// genuinely useful handful followed by a very long tail of places with a
    /// count of one — and the tail is most of the list *and* most of the
    /// payload. `limit` is what lets the landing screen ask for the handful.
    ///
    /// `q` filters by name, so a caller holding only the top twelve can still
    /// offer search over all of them without downloading the vocabulary first.
    /// Sorted by count here too: typing "spring" should offer the Springfield
    /// with four hundred photos before the one with two.
    @Sendable
    func places(req: Request) async throws -> PlacesResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.placesPageSize, 1), 2000)
        let sort = req.query[String.self, at: "sort"] ?? "count"

        let query = (req.query[String.self, at: "q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Matches everything when nothing was typed, so one query serves both
        // the landing screen and search rather than two that can disagree.
        let pattern = query.isEmpty ? "%" : "%\(escapeForLike(query))%"

        // Alphabetical is the right order for the full list, where the job is
        // finding a name you already have in mind rather than being shown what
        // you shoot most. Two screens, two jobs, two orders.
        let ordering = sort == "name"
            ? "name ASC"
            : "count DESC, name ASC"

        let rows = try await req.sql.raw("""
            SELECT a.place_name AS name, count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            GROUP BY a.place_name
            ORDER BY \(unsafeRaw: ordering)
            LIMIT \(bind: limit)
            """).all(decoding: PlaceRow.self)

        // Counted separately rather than inferred from `rows`, which is capped:
        // the "See All" row has to be able to say 340 while holding 12.
        struct CountRow: Decodable { let total: Int }
        let total = try await req.sql.raw("""
            SELECT count(DISTINCT a.place_name)::int AS total
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            """).first(decoding: CountRow.self)?.total ?? 0

        return PlacesResponse(
            places: rows.map { PlaceSummary(name: $0.name, count: $0.count) },
            total: total
        )
    }

    /// What the landing screen asks for when it doesn't say.
    static let placesPageSize = 12

    // MARK: - Search

    /// How many results one page carries.
    static let pageSize = 120

    @Sendable
    func search(req: Request) async throws -> SearchResults {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.pageSize, 1), 500)

        let place = (req.query[String.self, at: "place"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else {
            return SearchResults(items: [], total: 0, nextOffset: nil)
        }

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Substring, so typing "Virginia" finds "Culpeper County, Virginia" and
        // picking a place off the list finds exactly itself. `ILIKE` with a
        // leading wildcard cannot use a btree index, which is fine at this
        // scale — a sequential scan over one text column for a library of this
        // size is milliseconds, and a trigram index is one migration away if
        // that ever stops being true.
        let pattern = "%\(escapeForLike(place))%"

        struct CountRow: Decodable { let total: Int }
        let total = try await req.sql.raw("""
            SELECT count(*)::int AS total
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            """).first(decoding: CountRow.self)?.total ?? 0

        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            ORDER BY \(unsafeRaw: TimelineController.localTime) DESC, sa.id
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: TimelineController.ItemRow.self)

        let consumed = offset + rows.count
        return SearchResults(
            items: rows.map { $0.toItem() },
            total: total,
            nextOffset: consumed < total ? consumed : nil
        )
    }

    /// `%`, `_` and `\` are wildcards to `LIKE`. Someone searching for a place
    /// with an underscore in it should find that place, not every place.
    private func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
