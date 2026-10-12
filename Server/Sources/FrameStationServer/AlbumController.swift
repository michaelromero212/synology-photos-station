import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension AlbumListResponse: @retroactive Content {}
extension AlbumDTO: @retroactive Content {}
extension CreateAlbumRequest: @retroactive Content {}
extension UpdateAlbumRequest: @retroactive Content {}
extension AlbumAssetsRequest: @retroactive Content {}

/// Albums: collections you build by hand, cutting across dates. Two kinds,
/// chosen when one is made.
///
/// **Yours alone**, the default (`space_id` null). Private to its owner: nobody
/// else can see one, list one, or learn that it exists — including members of a
/// library whose photos it contains. Contents are placements in any library the
/// owner belongs to, re-checked on every read, so leaving a shared library
/// takes its photos back out rather than leaving a private window into a space
/// you were removed from.
///
/// **A family album** belongs to a shared library. Every member sees it, and it
/// holds only that library's photos: one added from somewhere else is shared
/// into the library first, as `share` does it, family notice and all, with the
/// original left where it was. Contributors add to it. Its creator or the
/// library's owner renames or deletes it, and a photo in it is taken out by
/// whoever added it, the album's creator or the library's owner. Viewers look.
/// Leaving the library leaves its albums behind, for the people still in it.
///
/// 404 rather than 403 wherever a refusal would confirm an album exists.
struct AlbumController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("albums", use: list)
        protected.post("albums", use: create)
        protected.get("albums", ":albumID", use: detail)
        protected.patch("albums", ":albumID", use: update)
        protected.delete("albums", ":albumID", use: delete)
        protected.get("albums", ":albumID", "items", use: items)
        protected.post("albums", ":albumID", "assets", use: addAssets)
        protected.delete("albums", ":albumID", "assets", ":spaceAssetID", use: removeAsset)
    }

    private struct IDRow: Decodable { let id: UUID }

    private struct AlbumRow: Decodable {
        let id: UUID
        let name: String
        let spaceID: UUID?
        let ownerUserID: UUID
        let itemCount: Int
        let coverAssetID: UUID?
        let createdAt: Date
        let updatedAt: Date
        /// The caller's role in a family album's library.
        let role: String?
    }

    /// An album the caller can see, and what they may do with it.
    private struct Access {
        let album: AlbumRow
        /// Rename, change the cover, delete.
        let manage: Bool
        let add: Bool
        /// Take out a photo somebody else added.
        let removeAny: Bool
    }

    private static func access(_ row: AlbumRow, caller: UUID) -> Access {
        // Yours alone: nobody else ever gets this far.
        guard row.spaceID != nil else {
            return Access(album: row, manage: true, add: true, removeAny: true)
        }
        let role = row.role.flatMap(SpaceRole.init(rawValue:))
        let contributes = role == .owner || role == .contributor
        let manages = contributes && (row.ownerUserID == caller || role == .owner)
        return Access(album: row, manage: manages, add: contributes, removeAny: manages)
    }

    private func dto(_ access: Access) -> AlbumDTO {
        let row = access.album
        return AlbumDTO(
            id: row.id, name: row.name,
            itemCount: row.itemCount, coverAssetID: row.coverAssetID,
            createdAt: row.createdAt, updatedAt: row.updatedAt,
            spaceID: row.spaceID, canManage: access.manage, canAdd: access.add
        )
    }

    // MARK: - Reading

    /// The caller's own albums, and with `?shared=true` the family albums of
    /// every shared library they belong to.
    ///
    /// Family albums only when asked for: an app from before them would file
    /// them under the person's own albums, as though they were private.
    private func list(_ req: Request) async throws -> AlbumListResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let family = req.query[Bool.self, at: "shared"] ?? false
        let rows = try await req.sql.raw("""
            \(Self.albumSelect(caller: device.userID))
            WHERE (a.space_id IS NULL AND a.owner_user_id = \(bind: device.userID))
               OR (\(bind: family) AND a.space_id IS NOT NULL AND m.user_id IS NOT NULL)
            ORDER BY a.updated_at DESC
            """).all(decoding: AlbumRow.self)
        return AlbumListResponse(
            albums: rows.map { dto(Self.access($0, caller: device.userID)) },
            includesFamilyAlbums: family ? true : nil
        )
    }

    private func detail(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    /// The album's photos, in album order — the one thing that differs from the
    /// timeline, which is always chronological.
    private func items(_ req: Request) async throws -> TimelineBucketPage {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        _ = try await requireReadable(albumID, device: device, on: req.sql)

        // A family album's photos come from its own library and nowhere else,
        // checked again here as well as when they were added.
        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
            FROM album_assets aa
            JOIN albums al ON al.id = aa.album_id
            JOIN space_assets sa ON sa.id = aa.space_asset_id
            JOIN assets a ON a.id = sa.asset_id
            JOIN space_members m ON m.space_id = sa.space_id
                                AND m.user_id = \(bind: device.userID)
            WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
              AND (al.space_id IS NULL OR sa.space_id = al.space_id)
            ORDER BY aa.position, aa.added_at
            """).all(decoding: TimelineController.ItemRow.self)

        // Reuses the timeline's page shape so the client renders albums with
        // the same grid, cells and thumbnail cache. `key` is the album id.
        return TimelineBucketPage(
            key: albumID.uuidString, zoom: .day, items: rows.map { $0.toItem() }
        )
    }

    // MARK: - Writing

    private func create(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(CreateAlbumRequest.self)

        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            throw Abort(.badRequest, reason: "An album needs a name.")
        }
        if let spaceID = input.spaceID {
            // A family album: in a shared library the person can add to. A
            // personal library has nobody else to share an album with.
            try await SpaceAccess.requireContributor(
                spaceID: spaceID, userID: device.userID, on: req.sql
            )
            guard try await req.sql.raw("""
                SELECT id FROM spaces WHERE id = \(bind: spaceID) AND kind = 'shared'
                """).first(decoding: IDRow.self) != nil else {
                throw Abort(.badRequest, reason: "Only a shared library has shared albums.")
            }
        }
        guard let created = try await req.sql.raw("""
            INSERT INTO albums (owner_user_id, name, created_by, space_id)
            VALUES (\(bind: device.userID), \(bind: name), \(bind: device.userID),
                    \(bind: input.spaceID))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not create the album.")
        }

        let album = try await requireReadable(created.id, device: device, on: req.sql)
        if !input.spaceAssetIDs.isEmpty {
            try await attach(input.spaceAssetIDs, to: album, device: device, req: req)
        }
        return dto(try await requireReadable(created.id, device: device, on: req.sql))
    }

    private func update(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(UpdateAlbumRequest.self)

        try Self.requireManage(try await requireReadable(albumID, device: device, on: req.sql))

        if let raw = input.name {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else {
                throw Abort(.badRequest, reason: "An album needs a name.")
            }
            try await req.sql.raw("""
                UPDATE albums SET name = \(bind: name), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
        }

        if let cover = input.coverAssetID {
            // The cover has to be something the album actually contains,
            // otherwise it becomes a way to display an arbitrary asset.
            guard try await req.sql.raw("""
                SELECT sa.id FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.asset_id = \(bind: cover)
                """).first(decoding: IDRow.self) != nil else {
                throw Abort(.badRequest, reason: "That photo isn't in this album.")
            }
            try await req.sql.raw("""
                UPDATE albums SET cover_asset_id = \(bind: cover), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
        }
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func delete(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        try Self.requireManage(try await requireReadable(albumID, device: device, on: req.sql))
        // Only the album row goes; album_assets cascades and the photos
        // themselves are untouched. Deleting a collection must never delete
        // the things collected.
        try await req.sql.raw("DELETE FROM albums WHERE id = \(bind: albumID)").run()
        return .noContent
    }

    private func addAssets(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(AlbumAssetsRequest.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireAdd(album)
        try await attach(input.spaceAssetIDs, to: album, device: device, req: req)
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func removeAsset(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let placementID = try req.parameters.require("spaceAssetID", as: UUID.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireAdd(album)

        struct AddedRow: Decodable { let addedBy: UUID }
        guard let added = try await req.sql.raw("""
            SELECT added_by AS "addedBy" FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).first(decoding: AddedRow.self) else {
            // Not in the album, so already out of it.
            return .noContent
        }
        guard album.removeAny || added.addedBy == device.userID else {
            throw Abort(
                .forbidden,
                reason: "Only the person who added it, the album's creator or the library's owner can take it out."
            )
        }
        try await req.sql.raw("""
            DELETE FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).run()
        try await refreshCover(albumID, on: req.sql)
        return .noContent
    }

    // MARK: - Helpers

    /// Adds placements, silently skipping any the caller can't see.
    ///
    /// The membership join is the whole security story: you may only collect
    /// photos already visible to you, and an unknown or forbidden id adds
    /// nothing rather than erroring — which also means this can't be used to
    /// probe whether an id exists.
    ///
    /// A family album holds only its library's photos. One from anywhere else
    /// is shared in first, from a library the caller can add to, the way
    /// `share` does it, and the album gets the library's copy.
    private func attach(
        _ placementIDs: [UUID], to album: Access,
        device: AuthenticatedDevice, req: Request
    ) async throws {
        guard !placementIDs.isEmpty else { return }
        guard placementIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Add at most 500 photos at a time.")
        }
        let albumID = album.album.id
        let library = album.album.spaceID

        var placements = placementIDs
        if let library {
            struct SeenRow: Decodable {
                let spaceID: UUID
                let assetID: UUID
                let role: String
            }
            placements = []
            for placementID in placementIDs {
                guard let seen = try await req.sql.raw("""
                    SELECT sa.space_id AS "spaceID", sa.asset_id AS "assetID", m.role
                    FROM space_assets sa
                    JOIN space_members m ON m.space_id = sa.space_id
                                        AND m.user_id = \(bind: device.userID)
                    WHERE sa.id = \(bind: placementID) AND sa.deleted_at IS NULL
                    """).first(decoding: SeenRow.self) else { continue }
                if seen.spaceID == library {
                    placements.append(placementID)
                    continue
                }
                // Sharing out of a library needs the same say there that
                // `share` asks for.
                guard SpaceRole(rawValue: seen.role) != .viewer else { continue }
                if let shared = try await MediaEditController.shareIn(
                    assetID: seen.assetID, from: seen.spaceID, to: library,
                    device: device, req: req
                ) {
                    placements.append(shared.placementID)
                }
            }
        }

        for placementID in placements {
            try await req.sql.raw("""
                INSERT INTO album_assets (album_id, space_asset_id, added_by, position)
                SELECT \(bind: albumID), sa.id, \(bind: device.userID),
                       COALESCE(
                           (SELECT MAX(position) + 1 FROM album_assets WHERE album_id = \(bind: albumID)),
                           0
                       )
                FROM space_assets sa
                JOIN space_members m ON m.space_id = sa.space_id
                WHERE sa.id = \(bind: placementID)
                  AND sa.deleted_at IS NULL
                  AND m.user_id = \(bind: device.userID)
                  AND sa.space_id = COALESCE(\(bind: library), sa.space_id)
                ON CONFLICT (album_id, space_asset_id) DO NOTHING
                """).run()
        }
        try await refreshCover(albumID, on: req.sql)
        try await req.sql.raw("""
            UPDATE albums SET updated_at = now() WHERE id = \(bind: albumID)
            """).run()
    }

    /// Keeps the cover pointing at something that is still in the album.
    private func refreshCover(_ albumID: UUID, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE albums SET cover_asset_id = (
                SELECT sa.asset_id
                FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
                ORDER BY aa.position, aa.added_at
                LIMIT 1
            )
            WHERE id = \(bind: albumID)
              AND (
                  cover_asset_id IS NULL
                  OR NOT EXISTS (
                      SELECT 1 FROM album_assets aa2
                      JOIN space_assets sa2 ON sa2.id = aa2.space_asset_id
                      WHERE aa2.album_id = \(bind: albumID)
                        AND sa2.asset_id = albums.cover_asset_id
                  )
              )
            """).run()
    }

    /// An album you own, or a family album in a library you belong to; any
    /// other id is a 404, so a refusal never confirms an album exists.
    private func requireReadable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> Access {
        guard let row = try await sql.raw("""
            \(Self.albumSelect(caller: device.userID))
            WHERE a.id = \(bind: albumID)
              AND ((a.space_id IS NULL AND a.owner_user_id = \(bind: device.userID))
                   OR (a.space_id IS NOT NULL AND m.user_id IS NOT NULL))
            """).first(decoding: AlbumRow.self) else {
            throw Abort(.notFound, reason: "No such album.")
        }
        return Self.access(row, caller: device.userID)
    }

    /// 403 from here on: the caller can see the album, so saying no reveals
    /// nothing they don't know.
    private static func requireManage(_ album: Access) throws {
        guard album.manage else {
            throw Abort(
                .forbidden,
                reason: "Only the album's creator or the library's owner can change it."
            )
        }
    }

    private static func requireAdd(_ album: Access) throws {
        guard album.add else {
            throw Abort(.forbidden, reason: "You have view-only access to this library.")
        }
    }

    /// An album, the caller's role in its library, and its count. The count
    /// re-checks membership: a personal album's against its owner's libraries,
    /// so its badge never promises photos they can no longer reach, and a
    /// family album's against its own library.
    private static func albumSelect(caller: UUID) -> SQLQueryString {
        """
        SELECT a.id, a.name, a.space_id AS "spaceID", a.owner_user_id AS "ownerUserID",
               a.cover_asset_id AS "coverAssetID",
               a.created_at AS "createdAt", a.updated_at AS "updatedAt",
               m.role,
               (SELECT count(*) FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = a.id AND sa.deleted_at IS NULL
                  AND CASE WHEN a.space_id IS NULL
                           THEN EXISTS (SELECT 1 FROM space_members m2
                                        WHERE m2.space_id = sa.space_id
                                          AND m2.user_id = a.owner_user_id)
                           ELSE sa.space_id = a.space_id END)::int AS "itemCount"
        FROM albums a
        LEFT JOIN space_members m ON m.space_id = a.space_id AND m.user_id = \(bind: caller)
        """
    }
}
