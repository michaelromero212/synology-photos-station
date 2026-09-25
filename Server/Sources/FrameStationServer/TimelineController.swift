import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension TimelineManifest: @retroactive Content {}
extension TimelineBucketPage: @retroactive Content {}
extension SpaceChanges: @retroactive Content {}
extension AssetDetail: @retroactive Content {}

/// The timeline: bucket manifest, per-bucket items, delta sync, and asset detail.
struct TimelineController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("spaces", ":spaceID", "timeline", use: manifest)
        protected.get("spaces", ":spaceID", "timeline", ":bucket", use: bucket)
        protected.get("spaces", ":spaceID", "changes", use: changes)
        protected.get("spaces", ":spaceID", "assets", ":assetID", "detail", use: detail)
    }

    /// Local wall-clock capture time, falling back to when we first saw the file.
    static let localTime = "COALESCE(a.local_captured_at, a.created_at AT TIME ZONE 'UTC')"

    /// Rows that are a thing somebody photographed, rather than a part of one.
    ///
    /// A Live Photo's paired video carries a `live_group_id` and nothing else
    /// does, so this is the whole test. Every query that counts or lists media
    /// needs it: without it a Live Photo is two tiles in the grid, two in the
    /// bucket count, two in a collection's total, and two in the rail's
    /// density — one thing, counted twice, in four places that then disagree
    /// with each other.
    static let visible = "NOT (a.media_type = 'video' AND a.live_group_id IS NOT NULL)"

    /// Everything `ItemRow` decodes, except the favorite flag.
    ///
    /// Shared because it drifted, and drifted silently. Five queries across four
    /// controllers build a `TimelineItem`, each with its own hand-written column
    /// list, and when `isBurst` was added to `ItemRow` two of them were not
    /// updated — search and an album's contents. Swift's synthesised `Decodable`
    /// requires a key for every non-optional property *whether or not it has a
    /// default*, so both endpoints answered 400 the moment they matched
    /// anything: search returned nothing but an error, and opening a hand-made
    /// album failed outright. Neither had a test, and an empty album and an
    /// empty search both look like success.
    ///
    /// The optional properties hid the rest of the drift rather than causing it.
    /// A missing key decodes as nil, so `thumbVersion` absent meant a client
    /// that could not cache-bust a regenerated thumbnail, and `sourceLocalID`
    /// absent meant a phone that would not draw its own copy — both degraded
    /// quietly, in two places, for as long as the lists disagreed.
    ///
    /// The favorite flag stays out because it needs the asking user's id as a
    /// bound parameter, and a shared raw string cannot carry one safely. Every
    /// caller adds that `EXISTS` itself; it is the one column that is genuinely
    /// per-request, and it is the column nobody has ever forgotten.
    static let itemColumns = """
               sa.id,
               sa.space_id   AS "spaceID",
               a.id          AS "assetID",
               \(localTime) AT TIME ZONE 'UTC' AS "capturedAt",
               -- The same moment to the millisecond, which the whole-second
               -- date on the wire cannot carry. See `TimelineItem.capturedAtMs`.
               floor(extract(epoch FROM (\(localTime) AT TIME ZONE 'UTC')) * 1000)::bigint
                             AS "capturedAtMs",
               a.width, a.height, a.orientation,
               a.media_type  AS "mediaType",
               a.duration_ms AS "durationMs",
               a.thumbhash   AS "thumbHash",
               COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "uploadedBy",
               (a.derived_at IS NOT NULL) AS "isDerived",
               (a.burst_id IS NOT NULL) AS "isBurst",
               a.thumb_version AS "thumbVersion",
               sa.source_local_id AS "sourceLocalID",
               -- The paired half of a Live Photo, so the viewer can play it
               -- from the still rather than from a tile of its own.
               (SELECT v.id FROM assets v
                WHERE v.live_group_id = a.live_group_id
                  AND v.media_type = 'video' LIMIT 1) AS "liveVideoAssetID"
        """

    private static func format(for zoom: TimelineZoom) -> String {
        switch zoom {
        case .year: return "YYYY"
        case .month: return "YYYY-MM"
        case .day: return "YYYY-MM-DD"
        }
    }

    // MARK: - Manifest

    private struct BucketRow: Decodable {
        let key: String
        let count: Int
        let place: String?
    }

    @Sendable
    func manifest(req: Request) async throws -> TimelineManifest {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let zoom = TimelineZoom(rawValue: req.query[String.self, at: "zoom"] ?? "day") ?? .day

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Allowlisted, never interpolated from the request.
        let pattern = Self.format(for: zoom)

        let rows = try await req.sql.raw("""
            SELECT to_char(\(unsafeRaw: Self.localTime), \(bind: pattern)) AS key,
                   count(*)::int AS count,
                   mode() WITHIN GROUP (ORDER BY a.place_name) AS place
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: Self.visible)
            GROUP BY 1
            ORDER BY 1 DESC
            """).all(decoding: BucketRow.self)

        return TimelineManifest(
            spaceID: spaceID,
            zoom: zoom,
            total: rows.reduce(0) { $0 + $1.count },
            cursor: try await currentCursor(spaceID: spaceID, on: req.sql),
            buckets: rows.map { TimelineBucket(key: $0.key, count: $0.count, place: $0.place) }
        )
    }

    // MARK: - Bucket items

    struct ItemRow: Decodable {
        let id: UUID
        let spaceID: UUID
        let assetID: UUID
        let capturedAt: Date
        let width: Int?
        let height: Int?
        let mediaType: String
        let durationMs: Int?
        let thumbHash: Data?
        let isFavorite: Bool
        let uploadedBy: UUID
        let isDerived: Bool
        let orientation: Int?
        var isBurst: Bool = false
        var liveVideoAssetID: UUID?
        /// Only ever set by the Recently Deleted query; every other caller
        /// leaves it nil, because nothing else in the library is on a clock.
        var purgeAt: Date?
        /// The thumbnail generation, so the client can cache-bust to a
        /// regenerated thumbnail. Nil where a query doesn't select it.
        var thumbVersion: Int?
        /// What the uploading device called this photograph. Lets that device
        /// draw its own copy while the NAS is still deriving — see
        /// `TimelineItem.sourceLocalID`.
        var sourceLocalID: String?
        /// `capturedAt` to the millisecond. Nil where a query doesn't select it.
        var capturedAtMs: Int64?

        func toItem() -> TimelineItem {
            // Orientation is applied here rather than baked into the stored
            // dimensions, so rotating a photo is one column write and every
            // reader agrees. exiftool reports the pixel grid and leaves the
            // rotation in a separate tag, so a portrait iPhone photo arrives as
            // 4032×3024 with orientation 6 — reporting that ratio straight
            // through laid every portrait shot out landscape.
            //
            // Square is the safest fallback: an item whose dimensions never
            // arrived should not distort the row it lands in.
            let ratio = ExifOrientation.aspectRatio(
                width: width, height: height, orientation: orientation
            ) ?? 1
            return TimelineItem(
                id: id,
                spaceID: spaceID,
                assetID: assetID,
                capturedAt: capturedAt,
                aspectRatio: ratio,
                mediaType: MediaType(rawValue: mediaType) ?? .photo,
                durationMs: durationMs,
                thumbHash: thumbHash?.base64EncodedString(),
                isFavorite: isFavorite,
                uploadedBy: uploadedBy,
                isDerived: isDerived,
                isBurst: isBurst,
                liveVideoAssetID: liveVideoAssetID,
                purgeAt: purgeAt,
                thumbVersion: thumbVersion,
                sourceLocalID: sourceLocalID,
                capturedAtMs: capturedAtMs
            )
        }
    }

    @Sendable
    func bucket(req: Request) async throws -> TimelineBucketPage {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let key = try req.parameters.require("bucket")
        let zoom = TimelineZoom(rawValue: req.query[String.self, at: "zoom"] ?? "day") ?? .day

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let pattern = Self.format(for: zoom)
        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: Self.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: Self.visible)
              AND to_char(\(unsafeRaw: Self.localTime), \(bind: pattern)) = \(bind: key)
            ORDER BY \(unsafeRaw: Self.localTime) DESC, sa.id
            """).all(decoding: ItemRow.self)

        return TimelineBucketPage(key: key, zoom: zoom, items: rows.map { $0.toItem() })
    }

    // MARK: - Delta sync

    private struct ChangeRow: Decodable {
        let seq: Int64
        let op: String
        let entityID: UUID
    }

    @Sendable
    func changes(req: Request) async throws -> SpaceChanges {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let since = req.query[Int64.self, at: "since"] ?? 0
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 500, 1), 1000)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let rows = try await req.sql.raw("""
            SELECT seq, op, entity_id AS "entityID"
            FROM change_log
            WHERE space_id = \(bind: spaceID)
              AND seq > \(bind: since)
              AND entity = 'space_asset'
            ORDER BY seq
            LIMIT \(bind: limit + 1)
            """).all(decoding: ChangeRow.self)

        let hasMore = rows.count > limit
        let page = hasMore ? Array(rows.prefix(limit)) : rows

        // Hydrate inserts and updates in one query rather than N round trips —
        // a client catching up after a week of uploads would otherwise make
        // hundreds of requests to fill in a single delta.
        let needsItem = page.filter { $0.op != "delete" }.map(\.entityID)
        var itemsByID: [UUID: TimelineItem] = [:]
        if !needsItem.isEmpty {
            // The shared column list, like every other query that builds an
            // item. This one kept a hand-written copy, which is how a new column
            // reaches the grid by one road and not the other.
            let hydrated = try await req.sql.raw("""
                SELECT \(unsafeRaw: Self.itemColumns),
                       EXISTS (
                           SELECT 1 FROM space_asset_favorites f
                           WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                       ) AS "isFavorite"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.id = ANY(\(bind: needsItem)) AND sa.deleted_at IS NULL
                  AND \(unsafeRaw: Self.visible)
                """).all(decoding: ItemRow.self)
            for row in hydrated { itemsByID[row.id] = row.toItem() }
        }

        let changes = page.map { row in
            SpaceChange(
                seq: row.seq,
                op: ChangeOperation(rawValue: row.op) ?? .update,
                entityID: row.entityID,
                item: itemsByID[row.entityID]
            )
        }

        return SpaceChanges(
            cursor: changes.last?.seq ?? since,
            hasMore: hasMore,
            changes: changes
        )
    }

    // MARK: - Detail

    private struct DetailRow: Decodable {
        let id: UUID
        let assetID: UUID
        let spaceID: UUID
        let mediaType: String
        let mime: String
        let byteSize: Int64
        let width: Int?
        let height: Int?
        let orientation: Int?
        let durationMs: Int?
        let capturedAt: Date?
        let capturedTZOffset: Int?
        let cameraMake: String?
        let cameraModel: String?
        let lens: String?
        let iso: Int?
        let aperture: Double?
        let shutter: String?
        let focalLength: Double?
        let exposureBias: Double?
        let dynamicRange: String?
        let isRaw: Bool
        let mediaSubtypes: [String]
        let isLive: Bool
        let isBurst: Bool
        let latitude: Double?
        let longitude: Double?
        let placeName: String?
        let uploadedByID: UUID
        let uploadedByName: String
        let uploadedAt: Date
        let spaceKind: String
        let filename: String?
        let description: String?
        let rating: Int?
        let isFavorite: Bool
        let onDevice: Bool
        /// The `exif` jsonb column as text, decoded to `[MetadataGroup]` below.
        /// Text rather than a jsonb-to-Codable decode so this one column can't
        /// fail the whole detail row if its shape ever drifts.
        let extendedMetadataJSON: String?
    }

    @Sendable
    func detail(req: Request) async throws -> AssetDetail {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        guard let row = try await req.sql.raw("""
            SELECT sa.id,
                sa.space_id AS "spaceID",
                   a.id AS "assetID",
                   a.media_type AS "mediaType",
                   a.mime,
                   a.byte_size AS "byteSize",
                   a.width, a.height, a.orientation,
                   a.duration_ms AS "durationMs",
                   a.captured_at AS "capturedAt",
                   a.captured_tz_off AS "capturedTZOffset",
                   a.camera_make AS "cameraMake",
                   a.camera_model AS "cameraModel",
                   a.lens,
                   a.iso,
                   a.aperture,
                   a.shutter,
                   a.focal_len AS "focalLength",
                   a.exposure_bias AS "exposureBias",
                   a.dynamic_range AS "dynamicRange",
                   a.is_raw AS "isRaw",
                   a.media_subtypes AS "mediaSubtypes",
                   (a.live_group_id IS NOT NULL) AS "isLive",
                   (a.burst_id IS NOT NULL) AS "isBurst",
                   a.lat AS latitude,
                   a.lon AS longitude,
                   a.place_name AS "placeName",
                   u.id AS "uploadedByID",
                   u.display_name AS "uploadedByName",
                   sa.uploaded_at AS "uploadedAt",
                   s.kind AS "spaceKind",
                   sa.filename,
                   sa.description,
                   sa.rating::int AS rating,
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite",
                   sa.on_device AS "onDevice",
                   a.exif::text AS "extendedMetadataJSON"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            -- The corrected credit when there is one, the uploader otherwise.
            -- `uploaded_by_user_id` stays untouched as the record of who sent
            -- the bytes; see migration 0016.
            JOIN users u ON u.id = COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id)
            JOIN spaces s ON s.id = sa.space_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.asset_id = \(bind: assetID)
              AND sa.deleted_at IS NULL
            """).first(decoding: DetailRow.self) else {
            throw Abort(.notFound, reason: "No such asset in this space.")
        }

        struct TagRow: Decodable { let name: String }
        let tags = try await req.sql.raw("""
            SELECT t.name FROM tags t
            JOIN space_asset_tags st ON st.tag_id = t.id
            WHERE st.space_asset_id = \(bind: row.id)
            ORDER BY lower(t.name)
            """).all(decoding: TagRow.self).map(\.name)

        // Reported as displayed, matching the grid and matching what the person
        // looking at the photo would measure. A rotated portrait that says
        // 4032 × 3024 in the Information panel reads as a bug.
        let displayed = ExifOrientation.displaySize(
            width: row.width, height: row.height, orientation: row.orientation
        )

        // The stored dump, decoded here rather than in the row so a shape
        // mismatch degrades to "no extra sections" instead of a failed detail.
        let extendedMetadata = row.extendedMetadataJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([MetadataGroup].self, from: $0) }

        return AssetDetail(
            id: row.id,
            assetID: row.assetID,
            spaceID: row.spaceID,
            mediaType: MediaType(rawValue: row.mediaType) ?? .photo,
            mime: row.mime,
            byteSize: row.byteSize,
            width: displayed.width,
            height: displayed.height,
            durationMs: row.durationMs,
            capturedAt: row.capturedAt,
            capturedTZOffset: row.capturedTZOffset,
            filename: row.filename,
            cameraMake: row.cameraMake,
            cameraModel: row.cameraModel,
            lens: row.lens,
            iso: row.iso,
            aperture: row.aperture,
            shutter: row.shutter,
            focalLength: row.focalLength,
            exposureBias: row.exposureBias,
            dynamicRange: row.dynamicRange,
            isRaw: row.isRaw,
            latitude: row.latitude,
            longitude: row.longitude,
            placeName: row.placeName,
            uploadedBy: UserDTO(id: row.uploadedByID, displayName: row.uploadedByName),
            uploadedAt: row.uploadedAt,
            isSharedSpace: row.spaceKind == "shared",
            description: row.description,
            rating: row.rating,
            tags: tags,
            isFavorite: row.isFavorite,
            onDevice: row.onDevice,
            mediaSubtypes: row.mediaSubtypes.compactMap(MediaSubtype.init(rawValue:)),
            isLive: row.isLive,
            isBurst: row.isBurst,
            extendedMetadata: extendedMetadata
        )
    }

    // MARK: - Helpers

    private struct CursorRow: Decodable { let seq: Int64? }

    private func currentCursor(spaceID: UUID, on sql: any SQLDatabase) async throws -> Int64 {
        let row = try await sql.raw("""
            SELECT max(seq) AS seq FROM change_log WHERE space_id = \(bind: spaceID)
            """).first(decoding: CursorRow.self)
        return row?.seq ?? 0
    }
}
