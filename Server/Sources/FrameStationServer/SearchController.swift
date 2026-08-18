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

    /// Every place this space has photos from, commonest first.
    ///
    /// Commonest rather than alphabetical because this list is the screen you
    /// land on before typing anything: the top of it should be where the family
    /// actually lives and holidays, not wherever happens to start with A.
    @Sendable
    func places(req: Request) async throws -> PlacesResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let rows = try await req.sql.raw("""
            SELECT a.place_name AS name, count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
            GROUP BY a.place_name
            ORDER BY count DESC, name
            """).all(decoding: PlaceRow.self)

        return PlacesResponse(
            places: rows.map { PlaceSummary(name: $0.name, count: $0.count) }
        )
    }

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
              AND a.place_name ILIKE \(bind: pattern)
            """).first(decoding: CountRow.self)?.total ?? 0

        let rows = try await req.sql.raw("""
            SELECT sa.id,
                   sa.space_id   AS "spaceID",
                   a.id          AS "assetID",
                   \(unsafeRaw: TimelineController.localTime) AT TIME ZONE 'UTC' AS "capturedAt",
                   a.width, a.height, a.orientation,
                   a.media_type  AS "mediaType",
                   a.duration_ms AS "durationMs",
                   a.thumbhash   AS "thumbHash",
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite",
                   COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "uploadedBy",
                   (a.derived_at IS NOT NULL) AS "isDerived"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
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
