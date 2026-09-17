import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension PlaybackURLResponse: @retroactive Content {}

/// Serves originals and derivatives.
///
/// Access is by *membership*, not ownership: you may read an asset if it is
/// placed in any space you belong to. That is what makes Family Shared work
/// without duplicating a byte.
struct AssetController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("assets", ":assetID", "thumb", use: thumbnail)
        protected.post("assets", ":assetID", "thumb", use: acceptThumbnail)
        protected.get("assets", ":assetID", "preview", use: preview)
        protected.get("assets", ":assetID", "original", use: original)
        protected.get("assets", ":assetID", "playback", use: playbackURL)
        protected.delete("spaces", ":spaceID", "assets", ":assetID", use: remove)

        // Signed rather than bearer-authenticated: AVPlayer fetches media
        // itself and an AirPlay receiver fetches it from another device
        // entirely, so neither can carry our Authorization header.
        routes.get("stream", ":assetID", use: stream)
    }

    private struct AssetRow: Decodable {
        let id: UUID
        let sha256: String
        let mediaType: String
        let blobExt: String
        let mime: String
        /// Where the canonical file lives. NULL for rows predating the library
        /// layout, which still read from the content-addressed store.
        let storagePath: String?
    }

    /// The file to serve: the library copy when there is one, the blob
    /// otherwise. See ARCHITECTURE.md §3a.
    private func fileURL(for asset: AssetRow, _ req: Request) -> URL {
        if let path = asset.storagePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return req.blobStore.blobPath(sha256: asset.sha256, fileExtension: asset.blobExt)
    }

    // MARK: - Removal

    /// Removes a photo from a library.
    ///
    /// Soft delete, and the file moves to `#recycle` beside it rather than
    /// being unlinked — Synology's convention, and one `LibraryScanner` already
    /// skips, so a later rescan won't quietly re-import what someone deleted.
    ///
    /// The row stays as the record that this was deliberate. Automatic backup
    /// reads it and declines to upload the photo again; without it, deleting
    /// something still on your camera roll would simply undo itself on the next
    /// run.
    @Sendable
    func remove(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        struct PlacementRow: Decodable {
            let id: UUID
        }
        guard let placement = try await req.sql.raw("""
            SELECT sa.id
            FROM space_assets sa
            WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
              AND sa.deleted_at IS NULL
            """).first(decoding: PlacementRow.self) else {
            throw Abort(.notFound, reason: "No such asset in this space.")
        }

        // Recording the removal is the whole of deleting, now.
        //
        // This used to move the file into `#recycle` here, which was wrong in
        // both directions once photographs started living in each member's
        // home. It moved the *blob*, so the bytes every other copy of that
        // photograph depends on went into a bin; and it left the copies in
        // people's homes exactly where they were, so a deleted photograph was
        // still sitting in File Station.
        //
        // The reconciler already does the right thing from this one column: its
        // stale pass withdraws the copy from every home on its next sweep, and
        // the retention sweeper takes the bytes at day \(Retention.days). Both
        // read state rather than being told, so a delete that races either of
        // them still comes out correct.
        try await req.sql.raw("""
            UPDATE space_assets
            SET deleted_at = now(), deleted_by = \(bind: device.userID)
            WHERE id = \(bind: placement.id)
            """).run()

        _ = try? await ChangeLog.append(
            spaceID: spaceID, entity: "space_asset", entityID: placement.id,
            op: "delete", on: req.sql
        )
        return .noContent
    }

    // MARK: - Playback

    @Sendable
    func playbackURL(req: Request) async throws -> PlaybackURLResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let asset = try await requireReadableAsset(req)
        guard asset.mediaType == "video" else {
            throw Abort(.badRequest, reason: "That asset isn't a video.")
        }

        // What the caller asked for, defaulting to the original so a client that
        // predates renditions behaves exactly as it always did.
        let requested = req.query[String.self, at: "quality"]
            .flatMap(PlaybackQuality.init(rawValue:)) ?? .default
        // Asking for the rendition doesn't conjure one: until the transcode has
        // run there is nothing to serve, and the original is a far better answer
        // than an error. `stream` makes the same check when it picks the file.
        let hasRendition = FileManager.default.fileExists(
            atPath: playbackRenditionPath(sha256: asset.sha256, req).path
        )
        let quality: PlaybackQuality = (requested == .mobile && hasRendition) ? .mobile : .original

        let expires = Int(Date().addingTimeInterval(PlaybackToken.lifetime).timeIntervalSince1970)
        let signature = PlaybackToken.sign(
            assetID: asset.id, userID: device.userID, expires: expires,
            quality: quality, key: PlaybackToken.secret(for: req.application)
        )
        var components = URLComponents()
        // The collection is registered under /v1, so the route this
        // builds must include it — a bare /stream 404s.
        components.path = "/v1/stream/\(asset.id.uuidString)"
        components.queryItems = [
            URLQueryItem(name: "u", value: device.userID.uuidString),
            URLQueryItem(name: "exp", value: String(expires)),
            URLQueryItem(name: "q", value: quality.rawValue),
            URLQueryItem(name: "sig", value: signature),
        ]
        guard let relative = components.string,
              let url = URL(string: relative, relativeTo: baseURL(req))?.absoluteURL
        else { throw Abort(.internalServerError, reason: "Could not build a playback URL.") }

        return PlaybackURLResponse(
            url: url, expiresAt: Date(timeIntervalSince1970: TimeInterval(expires)),
            // Says which representation the client actually got, so it can tell
            // the difference between "you asked for the rendition and here it
            // is" and "you asked, but it isn't built yet".
            kind: quality == .mobile ? "rendition" : "direct"
        )
    }

    /// Where the cellular rendition for a blob lives, built or not.
    private func playbackRenditionPath(sha256: String, _ req: Request) -> URL {
        req.application.blobStore
            .derivativeDirectory(sha256: sha256)
            .appendingPathComponent(Derivatives.playbackName)
    }

    /// The URL a player actually hits. Range-served, so scrubbing a 4K file
    /// fetches only the part being watched.
    @Sendable
    func stream(req: Request) async throws -> Response {
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        // Absent means original, matching links minted before renditions and
        // keeping those signatures valid.
        let quality = req.query[String.self, at: "q"]
            .flatMap(PlaybackQuality.init(rawValue:)) ?? .default
        guard let rawUser = req.query[String.self, at: "u"],
              let userID = UUID(uuidString: rawUser),
              let expires = req.query[Int.self, at: "exp"],
              let signature = req.query[String.self, at: "sig"],
              PlaybackToken.verify(
                  assetID: assetID, userID: userID, expires: expires, quality: quality,
                  signature: signature, key: PlaybackToken.secret(for: req.application)
              )
        else {
            // Same 404 as an unknown asset: a bad signature shouldn't reveal
            // that the asset exists.
            throw Abort(.notFound, reason: "No such asset.")
        }

        // The signature proves the link was issued; membership is still checked
        // now, so revoking someone mid-lifetime takes effect immediately.
        guard let asset = try await req.sql.raw("""
            SELECT a.id, a.sha256, a.media_type AS "mediaType",
                   a.blob_ext AS "blobExt", a.mime,
                   a.storage_path AS "storagePath"
            FROM assets a
            WHERE a.id = \(bind: assetID)
              AND EXISTS (
                  SELECT 1 FROM space_assets sa
                  JOIN space_members m ON m.space_id = sa.space_id
                  WHERE sa.asset_id = a.id AND sa.deleted_at IS NULL
                    AND m.user_id = \(bind: userID)
              )
            """).first(decoding: AssetRow.self) else {
            throw Abort(.notFound, reason: "No such asset.")
        }

        // The signature already fixed which representation this link is for, so
        // there is nothing to decide here beyond whether the file is present —
        // and if it somehow isn't, the original still plays. Its own mime, not
        // the asset's: the rendition is always MP4/H.264 whatever the source was.
        if quality == .mobile {
            let rendition = playbackRenditionPath(sha256: asset.sha256, req)
            if FileManager.default.fileExists(atPath: rendition.path) {
                return try await streamFile(
                    req, at: rendition, contentType: "video/mp4", immutable: true
                )
            }
            req.logger.warning(
                "playback rendition missing for \(asset.sha256.prefix(8)); serving original"
            )
        }

        let blob = fileURL(for: asset, req)
        return try await streamFile(req, at: blob, contentType: asset.mime, immutable: true)
    }

    /// Honours a reverse proxy, so a link minted behind DSM points at the
    /// public host rather than the container's own address.
    private func baseURL(_ req: Request) -> URL {
        if let configured = Environment.get("FRAMESTATION_PUBLIC_URL"),
           let url = URL(string: configured) {
            return url
        }
        let proto = req.headers.first(name: "x-forwarded-proto") ?? "http"
        let host = req.headers.first(name: "x-forwarded-host")
            ?? req.headers.first(name: .host) ?? "localhost"
        return URL(string: "\(proto)://\(host)") ?? URL(string: "http://localhost")!
    }

    // MARK: - Endpoints

    @Sendable
    func thumbnail(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let size = req.query[Int.self, at: "size"] ?? 256
        guard Derivatives.eagerSizes.contains(size) else {
            throw Abort(.badRequest,
                        reason: "size must be one of \(Derivatives.eagerSizes.map(String.init).joined(separator: ", ")).")
        }

        let path = req.blobStore.derivativePath(sha256: asset.sha256, name: "thumb-\(size).jpg")
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Still queued, or the queue failed. 202 rather than 404 so the
            // client knows to keep the ThumbHash placeholder and retry, instead
            // of caching a miss forever.
            throw Abort(.accepted, reason: "Thumbnail not generated yet.")
        }
        return try await streamFile(req, at: path, contentType: "image/jpeg", immutable: true)
    }

    /// Takes the thumbnail the uploading device already made.
    ///
    /// The point is *whose* screen it fills. A device that uploads can draw the
    /// photo from its own camera roll while the NAS catches up; nobody else
    /// can, so on every other phone in the family the tile is grey until the
    /// derivation queue gets there. On a modest NAS mid-backup that is a long
    /// time, and it is exactly when people are watching to see that the photos
    /// arrived. Handing the picture over with the upload turns that wait into
    /// nothing, and costs the NAS no CPU at all.
    ///
    /// Written exactly as derivation writes: the file under the same
    /// derivative name the GET serves, the ThumbHash and `derived_at` on the
    /// row, and a `/changes` row per space so other devices are *told* rather
    /// than left to find out on their next cold start. That last part is the
    /// difference between this working and this appearing not to work.
    ///
    /// Not trusted permanently. The derivation job stays queued, so the
    /// server's own rendering replaces this whenever it runs — a device that
    /// sends a poor thumbnail, or one that no longer matches after an edit, is
    /// corrected rather than believed forever.
    @Sendable
    func acceptThumbnail(req: Request) async throws -> HTTPStatus {
        // Readable is the right bar, not "uploader". Anyone who can see the
        // asset could fetch this same thumbnail a second later anyway, the
        // write is idempotent, and derivation overwrites it regardless — so a
        // stricter check would buy nothing and would break the ordinary case
        // of a second device finishing an upload the first one started.
        let asset = try await requireReadableAsset(req)
        let body = try req.content.decode(UploadThumbnailRequest.self)

        guard body.jpeg.count <= UploadThumbnailRequest.maxBytes else {
            throw Abort(.payloadTooLarge, reason: "Thumbnail is too large.")
        }
        guard Derivatives.eagerSizes.contains(body.size) else {
            throw Abort(.badRequest,
                        reason: "size must be one of \(Derivatives.eagerSizes.map(String.init).joined(separator: ", ")).")
        }
        // Cheap shape check so a mislabelled body cannot land where a JPEG is
        // served with `image/jpeg`. Two bytes, and it is the whole of what we
        // can honestly verify without decoding.
        guard body.jpeg.count > 2, body.jpeg[body.jpeg.startIndex] == 0xFF,
              body.jpeg[body.jpeg.index(after: body.jpeg.startIndex)] == 0xD8 else {
            throw Abort(.badRequest, reason: "Thumbnail is not a JPEG.")
        }

        let path = req.blobStore.derivativePath(sha256: asset.sha256, name: "thumb-\(body.size).jpg")
        // Never over the server's own work. Once derivation has run, its
        // rendering is the better one and this request is a straggler from a
        // client that didn't know yet.
        var changedSomething = false
        if !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try body.jpeg.write(to: path, options: .atomic)
            changedSomething = true
        }

        let assetID = asset.id
        let thumbHash = body.thumbHash.map { ByteBuffer(bytes: $0) }
        try await req.application.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // `COALESCE` under a `WHERE` that matches only rows still
                // missing something: a row that already has the server's own
                // ThumbHash keeps it, `derived_at` is only claimed if nothing
                // has claimed it, and — the part that matters at scale — a row
                // that already has both is not written at all.
                struct Touched: Decodable { let id: UUID }
                let updated = try await sql.raw("""
                    UPDATE assets
                    SET thumbhash  = COALESCE(thumbhash, \(bind: thumbHash)),
                        derived_at = COALESCE(derived_at, now())
                    WHERE id = \(bind: assetID)
                      AND (thumbhash IS NULL OR derived_at IS NULL)
                    RETURNING id
                    """).all(decoding: Touched.self)
                changedSomething = changedSomething || !updated.isEmpty

                // Announced only when there is something to announce.
                //
                // Clients send this after every upload, and an upload that
                // deduplicates onto a photograph the NAS already knows changes
                // nothing. Announcing regardless would put one delta row per
                // photo through `/changes` every time somebody re-ran a backup
                // over a library that was already safe — waking every device in
                // the house to tell it nothing happened.
                if changedSomething {
                    let placements = try await sql.raw("""
                        SELECT id, space_id AS "spaceID" FROM space_assets
                        WHERE asset_id = \(bind: assetID) AND deleted_at IS NULL
                        """).all(decoding: DerivationWorker.SpacePlacement.self)

                    for placement in placements {
                        _ = try await ChangeLog.append(
                            spaceID: placement.spaceID, entity: "space_asset",
                            entityID: placement.id, op: "update", on: sql
                        )
                    }
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return .noContent
    }

    /// Full-screen preview, rendered on first request.
    ///
    /// Generating all 100k of these eagerly would cost ~40 GB and turn the
    /// import into a multi-day job; most photos are never opened full screen.
    @Sendable
    func preview(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let blob = fileURL(for: asset, req)
        guard FileManager.default.fileExists(atPath: blob.path) else {
            throw Abort(.notFound, reason: "Original is missing from storage.")
        }

        let path = try await Derivatives.makePreview(
            blob: blob,
            sha256: asset.sha256,
            mediaType: MediaType(rawValue: asset.mediaType) ?? .photo,
            store: req.blobStore
        )
        return try await streamFile(req, at: path, contentType: "image/jpeg", immutable: true)
    }

    /// Byte-exact original. Range-capable so video scrubbing works.
    @Sendable
    func original(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let blob = fileURL(for: asset, req)
        guard FileManager.default.fileExists(atPath: blob.path) else {
            throw Abort(.notFound, reason: "Original is missing from storage.")
        }
        return try await streamFile(req, at: blob, contentType: asset.mime, immutable: true)
    }

    // MARK: - Helpers

    private func requireReadableAsset(_ req: Request) async throws -> AssetRow {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        // 404 rather than 403 on a non-member: the existence of an asset is
        // itself information someone outside the space shouldn't get.
        guard let asset = try await req.sql.raw("""
            SELECT a.id,
                   a.sha256,
                   a.media_type AS "mediaType",
                   a.blob_ext   AS "blobExt",
                   a.mime,
                   a.storage_path AS "storagePath"
            FROM assets a
            WHERE a.id = \(bind: assetID)
              AND EXISTS (
                  SELECT 1
                  FROM space_assets sa
                  JOIN space_members m ON m.space_id = sa.space_id
                  WHERE sa.asset_id = a.id
                    AND sa.deleted_at IS NULL
                    AND m.user_id = \(bind: device.userID)
              )
            """).first(decoding: AssetRow.self) else {
            throw Abort(.notFound, reason: "No such asset.")
        }
        return asset
    }

    private func streamFile(
        _ req: Request,
        at path: URL,
        contentType: String,
        immutable: Bool
    ) async throws -> Response {
        // A missing file is a 404, not a 500.
        //
        // `asyncStreamFile` on a path that isn't there throws something Vapor
        // renders as "Internal Server Error", which tells the player nothing and
        // tells whoever reads the log even less — the video simply refuses to
        // play. `preview` already guarded for this; the streaming path did not,
        // so a blob missing from storage looked like a server fault rather than
        // an absent file. Worth saying plainly: it is the difference between
        // "your NAS is broken" and "this one file isn't where it should be".
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw Abort(.notFound, reason: "Original is missing from storage.")
        }
        let response = try await req.fileio.asyncStreamFile(at: path.path)
        response.headers.replaceOrAdd(name: .contentType, value: contentType)
        // Vapor serves 206 for a Range request but doesn't advertise the
        // capability. Players read this header to decide whether seeking is
        // possible at all — without it AVPlayer won't let you scrub.
        response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
        if immutable {
            // Everything here is content-addressed, so a given URL's bytes can
            // never change. Cache hard — this is most of what makes scrolling
            // back through the timeline feel instant.
            response.headers.replaceOrAdd(
                name: .cacheControl, value: "private, max-age=31536000, immutable"
            )
        }
        return response
    }
}
