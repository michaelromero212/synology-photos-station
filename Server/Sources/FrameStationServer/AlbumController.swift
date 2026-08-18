import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension AlbumListResponse: @retroactive Content {}
extension AlbumDTO: @retroactive Content {}
extension CreateAlbumRequest: @retroactive Content {}
extension UpdateAlbumRequest: @retroactive Content {}
extension AlbumAssetsRequest: @retroactive Content {}

/// Albums: collections you build by hand, cutting across dates.
///
/// Private to their owner. Nobody else can see one, list one, or learn that it
/// exists — including members of a library whose photos it contains.
///
/// Contents are `space_assets` placements rather than bare assets, and every
/// read re-checks that the owner is still a member of each placement's space.
/// So an album may draw from a shared library, but leaving that library takes
/// those photos out of the album rather than leaving a private window into a
/// space you were removed from.
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
        let itemCount: Int
        let coverAssetID: UUID?
        let createdAt: Date
        let updatedAt: Date
    }

    private func dto(_ row: AlbumRow) -> AlbumDTO {
        AlbumDTO(
            id: row.id, name: row.name,
            itemCount: row.itemCount, coverAssetID: row.coverAssetID,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    // MARK: - Reading

    /// Every album in every space the caller belongs to.
    private func list(_ req: Request) async throws -> AlbumListResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let rows = try await req.sql.raw("""
            \(raw: Self.albumSelect)
            WHERE a.owner_user_id = \(bind: device.userID)
            ORDER BY a.updated_at DESC
            """).all(decoding: AlbumRow.self)
        return AlbumListResponse(albums: rows.map(dto))
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

        let rows = try await req.sql.raw("""
            SELECT sa.id,
                   sa.space_id   AS "spaceID",
                   a.id          AS "assetID",
                   \(unsafeRaw: TimelineController.localTime) AT TIME ZONE 'UTC' AS "capturedAt",
                   a.width, a.height,
                   a.media_type  AS "mediaType",
                   a.duration_ms AS "durationMs",
                   a.thumbhash   AS "thumbHash",
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite",
                   COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "uploadedBy",
                   (a.derived_at IS NOT NULL) AS "isDerived"
            FROM album_assets aa
            JOIN space_assets sa ON sa.id = aa.space_asset_id
            JOIN assets a ON a.id = sa.asset_id
            JOIN space_members m ON m.space_id = sa.space_id
                                AND m.user_id = \(bind: device.userID)
            WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
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
        guard let created = try await req.sql.raw("""
            INSERT INTO albums (owner_user_id, name, created_by)
            VALUES (\(bind: device.userID), \(bind: name), \(bind: device.userID))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not create the album.")
        }

        if !input.spaceAssetIDs.isEmpty {
            try await attach(input.spaceAssetIDs, to: created.id, by: device.userID, on: req.sql)
        }
        return dto(try await requireReadable(created.id, device: device, on: req.sql))
    }

    private func update(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(UpdateAlbumRequest.self)

        let album = try await requireWritable(albumID, device: device, on: req.sql)

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
        _ = album
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func delete(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        _ = try await requireWritable(albumID, device: device, on: req.sql)
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

        _ = try await requireWritable(albumID, device: device, on: req.sql)
        try await attach(input.spaceAssetIDs, to: albumID, by: device.userID, on: req.sql)
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func removeAsset(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let placementID = try req.parameters.require("spaceAssetID", as: UUID.self)

        _ = try await requireWritable(albumID, device: device, on: req.sql)
        try await req.sql.raw("""
            DELETE FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).run()
        try await refreshCover(albumID, on: req.sql)
        return .noContent
    }

    // MARK: - Helpers

    /// Adds placements, silently ignoring any the owner can't see.
    ///
    /// The membership join is the whole security story: you may only collect
    /// photos already visible to you, and an unknown or forbidden id adds
    /// nothing rather than erroring — which also means this can't be used to
    /// probe whether an id exists.
    private func attach(
        _ placementIDs: [UUID], to albumID: UUID,
        by userID: UUID, on sql: any SQLDatabase
    ) async throws {
        guard !placementIDs.isEmpty else { return }
        guard placementIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Add at most 500 photos at a time.")
        }

        for placementID in placementIDs {
            try await sql.raw("""
                INSERT INTO album_assets (album_id, space_asset_id, added_by, position)
                SELECT \(bind: albumID), sa.id, \(bind: userID),
                       COALESCE(
                           (SELECT MAX(position) + 1 FROM album_assets WHERE album_id = \(bind: albumID)),
                           0
                       )
                FROM space_assets sa
                JOIN space_members m ON m.space_id = sa.space_id
                WHERE sa.id = \(bind: placementID)
                  AND sa.deleted_at IS NULL
                  AND m.user_id = \(bind: userID)
                ON CONFLICT (album_id, space_asset_id) DO NOTHING
                """).run()
        }
        try await refreshCover(albumID, on: sql)
        try await sql.raw("""
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

    /// 404 rather than 403 throughout: a refused album must not confirm one
    /// with that id exists.
    private func requireReadable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> AlbumRow {
        guard let row = try await sql.raw("""
            \(raw: Self.albumSelect)
            WHERE a.id = \(bind: albumID) AND a.owner_user_id = \(bind: device.userID)
            """).first(decoding: AlbumRow.self) else {
            throw Abort(.notFound, reason: "No such album.")
        }
        return row
    }

    /// Same as readable: you own it or it doesn't exist as far as you're
    /// concerned.
    private func requireWritable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> AlbumRow {
        try await requireReadable(albumID, device: device, on: sql)
    }

    /// The count re-checks membership too, so an album's badge never promises
    /// photos the owner can no longer reach.
    private static let albumSelect = """
        SELECT a.id, a.name,
               a.cover_asset_id AS "coverAssetID",
               a.created_at AS "createdAt", a.updated_at AS "updatedAt",
               (SELECT count(*) FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                JOIN space_members m2 ON m2.space_id = sa.space_id
                                     AND m2.user_id = a.owner_user_id
                WHERE aa.album_id = a.id AND sa.deleted_at IS NULL)::int AS "itemCount"
        FROM albums a
        """
}
