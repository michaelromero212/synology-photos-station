import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension EditCaptureTimeRequest: @retroactive Content {}
extension RotateMediaRequest: @retroactive Content {}
extension MediaEditResponse: @retroactive Content {}
extension SetCreditRequest: @retroactive Content {}
extension ShareAssetsRequest: @retroactive Content {}
extension ShareAssetsResponse: @retroactive Content {}

/// Correcting what a photo says about itself: when it was taken, and which way
/// up it goes.
///
/// Neither of these rewrites the original. `assets.sha256` is UNIQUE and is the
/// asset's identity — the derivative directories are keyed by it and the upload
/// path dedupes on it — so re-encoding a file to bake in a new EXIF tag would
/// change the primary key of the thing being edited. The record moves; the bytes
/// do not.
///
/// A date change does move the *file*, though, because the library layout puts
/// the date in the path: a photo re-dated into August belongs in `2026/08`, and
/// leaving it in `2026/07` would make File Station and the app disagree about
/// the same photo. That relocation is the part a NAS owner will go and check.
struct MediaEditController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.post("spaces", ":spaceID", "assets", "capture-time", use: editCaptureTime)
        protected.post("spaces", ":spaceID", "assets", "orientation", use: rotate)
        protected.post("spaces", ":spaceID", "assets", "credit", use: setCredit)
        protected.post("spaces", ":spaceID", "assets", "share", use: share)
    }

    private struct IDRow: Decodable { let id: UUID }

    private struct SpaceRow: Decodable {
        let id: UUID
        let name: String
        let kind: String
    }

    /// Puts photos into a shared space, leaving them where they already are.
    ///
    /// This used to be a move, and the move was wrong. Sharing a photo with the
    /// family is not a statement that you want it out of your own library —
    /// those are two decisions, and running them together means the second one
    /// gets made silently, by an app, on someone's behalf. So the source
    /// placement is untouched here and the app offers the removal afterwards,
    /// once the photos are visibly sitting in the destination.
    ///
    /// The copy is the same one `link` performs: a hard link into the shared
    /// tree plus that space's own asset row, so the shared library's contents
    /// live in the shared folder rather than inside somebody's home directory,
    /// and the file is stored once. See ARCHITECTURE.md §3a.
    ///
    /// Every item recorded through `ActivityTracker`, which is what turns a
    /// batch of shares into the single "Morgan added 10 photos to Family Shared"
    /// push the family actually receives. Sharing is the moment worth telling
    /// people about; an upload into your own library is not.
    ///
    /// Destination must be a shared space you can contribute to. Adding *into*
    /// someone's personal library would put your photos in their private tree,
    /// which is not something one member of a household should be able to do to
    /// another.
    @Sendable
    func share(req: Request) async throws -> ShareAssetsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(ShareAssetsRequest.self)
        guard !input.assetIDs.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to share.")
        }
        guard input.assetIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Share at most 500 items at once.")
        }

        let sourceID = try await requireContributorSpace(req)
        guard sourceID != input.destinationSpaceID else {
            throw Abort(.badRequest, reason: "That's already where they are.")
        }
        try await SpaceAccess.requireContributor(
            spaceID: input.destinationSpaceID, userID: device.userID, on: req.sql
        )

        guard let destination = try await req.sql.raw("""
            SELECT id, name, kind FROM spaces WHERE id = \(bind: input.destinationSpaceID)
            """).first(decoding: SpaceRow.self) else {
            throw Abort(.notFound, reason: "No such space.")
        }
        guard destination.kind == "shared" else {
            throw Abort(.forbidden, reason: "Photos can only be shared into a shared space.")
        }

        struct SourceRow: Decodable {
            let mediaType: String
        }

        var landed: [UUID] = []
        var sources: [UUID] = []

        // Deliberately not one big transaction. Copying makes a file on disk per
        // item, and a rollback cannot unmake those — so a failure halfway would
        // leave the tree holding links the database had forgotten. Per-item
        // instead: each photo either arrives completely or not at all, and the
        // response says which ones did.
        for assetID in input.assetIDs {
            // You may only place a photo you can already see. Without this,
            // holding an asset id would be enough to pull any file in the
            // household into a space you happen to belong to — and ids leak far
            // more easily than blobs do. Skipped rather than refused, so one
            // stale id in a batch doesn't discard the other forty-nine.
            guard let source = try await req.sql.raw("""
                SELECT a.media_type AS "mediaType" FROM assets a
                WHERE a.id = \(bind: assetID)
                  AND EXISTS (
                      SELECT 1 FROM space_assets sa
                      WHERE sa.asset_id = a.id AND sa.space_id = \(bind: sourceID)
                        AND sa.deleted_at IS NULL
                  )
                """).first(decoding: SourceRow.self) else { continue }

            // Already there: nothing to copy and nothing to announce. Sharing
            // the same photo twice should be quiet, not a second notification.
            let existing = try await req.sql.raw("""
                SELECT sa.id FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: destination.id) AND sa.deleted_at IS NULL
                  AND a.sha256 = (SELECT sha256 FROM assets WHERE id = \(bind: assetID))
                """).first(decoding: IDRow.self)
            if existing != nil { continue }

            let targetAssetID = try await UploadController.copyIntoSpace(
                assetID: assetID, spaceID: destination.id, device: device, req: req
            ) ?? assetID

            try await req.withPinnedConnection { sql in
                try await sql.raw("BEGIN").run()
                do {
                    guard let placement = try await sql.raw("""
                        INSERT INTO space_assets
                            (space_id, asset_id, uploaded_by_user_id, source_device_id)
                        VALUES
                            (\(bind: destination.id), \(bind: targetAssetID),
                             \(bind: device.userID), \(bind: device.deviceID))
                        ON CONFLICT (space_id, asset_id)
                        DO UPDATE SET deleted_at = NULL
                        RETURNING id
                        """).first(decoding: IDRow.self) else {
                        throw Abort(.internalServerError, reason: "Could not place asset in space.")
                    }

                    _ = try await ChangeLog.append(
                        spaceID: destination.id, entity: "space_asset",
                        entityID: placement.id, op: "insert", on: sql
                    )
                    try await ActivityTracker.record(
                        spaceID: destination.id,
                        userID: device.userID,
                        mediaType: MediaType(rawValue: source.mediaType) ?? .photo,
                        on: sql
                    )
                    try await sql.raw("COMMIT").run()
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }

            landed.append(targetAssetID)
            sources.append(assetID)
        }

        return ShareAssetsResponse(
            shared: landed.count,
            assetIDs: landed,
            sourceAssetIDs: sources,
            destinationSpaceID: destination.id
        )
    }

    /// Corrects who a photo is attributed to.
    ///
    /// Additive: `uploaded_by_user_id` is never touched, because it is a fact
    /// about which account sent the bytes and the upload path depends on it.
    /// The credit is a separate column that display prefers, and clearing it
    /// returns to the truth rather than to another guess. Who made the
    /// correction and when are recorded alongside, so an attribution that looks
    /// wrong later can be traced rather than argued about.
    ///
    /// The person credited must be a member of the space — crediting someone
    /// who cannot see the photo would put a name on it that nobody can resolve.
    @Sendable
    func setCredit(req: Request) async throws -> MediaEditResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(SetCreditRequest.self)
        guard !input.assetIDs.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to credit.")
        }
        guard input.assetIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Credit at most 500 items at once.")
        }

        let spaceID = try await requireContributorSpace(req)

        if let creditedTo = input.creditedTo {
            try await SpaceAccess.requireMembership(
                spaceID: spaceID, userID: creditedTo, on: req.sql
            )
        }

        var updated = 0
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                for assetID in input.assetIDs {
                    guard let target = try await Self.target(
                        assetID: assetID, spaceID: spaceID, on: sql
                    ) else { continue }

                    try await sql.raw("""
                        UPDATE space_assets
                        SET credited_to_user_id = \(bind: input.creditedTo),
                            credited_by_user_id = \(bind: input.creditedTo == nil ? nil : device.userID),
                            credited_at         = \(bind: input.creditedTo == nil ? nil : Date())
                        WHERE id = \(bind: target.placementID)
                        """).run()

                    _ = try await ChangeLog.append(
                        spaceID: spaceID, entity: "space_asset",
                        entityID: target.placementID, op: "update", on: sql
                    )
                    updated += 1
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        return MediaEditResponse(updated: updated)
    }

    private struct TargetRow: Decodable {
        let placementID: UUID
        let capturedAt: Date?
        let storagePath: String?
        let filename: String?
        let sha256: String?
        let orientation: Int?
    }

    // MARK: - Capture time

    @Sendable
    func editCaptureTime(req: Request) async throws -> MediaEditResponse {
        let input = try req.content.decode(EditCaptureTimeRequest.self)
        guard !input.items.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to re-time.")
        }
        // A cap, so a runaway client can't ask the NAS to move ten thousand
        // files inside one request with no way to see progress.
        guard input.items.count <= 500 else {
            throw Abort(.badRequest, reason: "Re-time at most 500 items at once.")
        }

        let spaceID = try await requireContributorSpace(req)
        var updated = 0
        var relocated = 0
        var moves: [(from: String, to: String)] = []

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                for item in input.items {
                    guard let target = try await Self.target(
                        assetID: item.assetID, spaceID: spaceID, on: sql
                    ) else { continue }

                    try await sql.raw("""
                        UPDATE assets
                        SET captured_at = \(bind: item.capturedAt),
                            local_captured_at =
                                (\(bind: item.capturedAt)
                                 + COALESCE(captured_tz_off, 0) * interval '1 second')
                                AT TIME ZONE 'UTC'
                        WHERE id = \(bind: item.assetID)
                        """).run()

                    // Other devices learn about this the same way they learn
                    // about everything else — the photo has to re-bucket on
                    // their timelines, not just on the one that edited it.
                    _ = try await ChangeLog.append(
                        spaceID: spaceID, entity: "space_asset",
                        entityID: target.placementID, op: "update", on: sql
                    )
                    updated += 1

                    if let path = target.storagePath,
                       let destination = Self.relocationTarget(for: path, newDate: item.capturedAt) {
                        moves.append((path, destination))
                    }
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        // Deliberately after the commit. A half-applied batch of file moves is
        // recoverable — `rebuild` reads the folders — but a database that
        // rolled back while the files had already moved is not.
        for move in moves {
            guard let landed = Self.move(
                from: move.from, to: move.to, logger: req.logger
            ) else { continue }
            relocated += 1
            try? await req.sql.raw("""
                UPDATE assets SET storage_path = \(bind: landed)
                WHERE storage_path = \(bind: move.from)
                """).run()
        }

        return MediaEditResponse(updated: updated, relocated: relocated)
    }

    // MARK: - Rotation

    @Sendable
    func rotate(req: Request) async throws -> MediaEditResponse {
        let input = try req.content.decode(RotateMediaRequest.self)
        guard !input.assetIDs.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to rotate.")
        }
        guard input.assetIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Rotate at most 500 items at once.")
        }

        let spaceID = try await requireContributorSpace(req)
        var updated = 0
        var stalePreviews: [String] = []

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                for assetID in input.assetIDs {
                    guard let target = try await Self.target(
                        assetID: assetID, spaceID: spaceID, on: sql
                    ) else { continue }

                    // Only the tag changes. Stored width and height stay as the
                    // pixels actually are; readers apply the orientation when
                    // they report a shape, so there is one source of truth for
                    // which way up this photo goes.
                    let next = ExifOrientation.rotated(target.orientation, by: input.rotation)
                    try await sql.raw("""
                        UPDATE assets SET orientation = \(bind: next) WHERE id = \(bind: assetID)
                        """).run()

                    // Thumbnails are baked with the rotation applied, so they
                    // are now wrong and have to be made again. Queued rather
                    // than rendered here: rotating a holiday's worth of photos
                    // must not hold the request open for minutes on a J4125.
                    try await DerivationWorker.enqueue(
                        assetID: assetID, kind: "thumbnails", on: sql
                    )
                    _ = try await ChangeLog.append(
                        spaceID: spaceID, entity: "space_asset",
                        entityID: target.placementID, op: "update", on: sql
                    )
                    updated += 1
                    if let sha256 = target.sha256 { stalePreviews.append(sha256) }
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        // The 2048 preview is rendered lazily on first full-screen view, so
        // deleting it is enough — the next viewer re-renders it the right way
        // up. Leaving it would show a correct grid and a sideways viewer.
        for sha256 in stalePreviews {
            let preview = req.blobStore.derivativePath(sha256: sha256, name: "preview-2048.jpg")
            try? FileManager.default.removeItem(at: preview)
        }

        return MediaEditResponse(updated: updated)
    }

    // MARK: - Access

    /// Both endpoints act on a whole selection, so the contributor check is per
    /// space rather than per asset — the same gate `AssetController.remove` uses.
    private func requireContributorSpace(_ req: Request) async throws -> UUID {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        return spaceID
    }

    /// Skips silently rather than aborting when an asset isn't in this space:
    /// a selection can go stale between opening the sheet and applying it, and
    /// failing the whole batch because one photo was removed elsewhere would be
    /// worse than re-timing the other forty-nine.
    private static func target(
        assetID: UUID, spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> TargetRow? {
        // `filename` is on the *placement*, not the asset — one file can sit in
        // several spaces under different names, so it cannot live on the row
        // that is keyed by content hash. This selected `a.filename` and threw
        // `column a.filename does not exist` on every call, which took editing a
        // capture time and rotating a photo down with it: both go through here.
        try await sql.raw("""
            SELECT sa.id AS "placementID", a.captured_at AS "capturedAt",
                   a.storage_path AS "storagePath", sa.filename, a.sha256,
                   a.orientation
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
              AND sa.deleted_at IS NULL
            """).first(decoding: TargetRow.self)
    }

    // MARK: - Moving the file

    /// Where a re-dated file belongs, or nil if it shouldn't move.
    ///
    /// Only rewrites a trailing `YYYY/MM`, and only when those components really
    /// do look like a year and a month. A library laid out some other way — or a
    /// file sitting somewhere unexpected — is left exactly where it is rather
    /// than being reorganised on a guess.
    static func relocationTarget(for path: String, newDate: Date) -> String? {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let monthDirectory = url.deletingLastPathComponent()
        let yearDirectory = monthDirectory.deletingLastPathComponent()

        let month = monthDirectory.lastPathComponent
        let year = yearDirectory.lastPathComponent
        guard year.count == 4, Int(year) != nil,
              month.count == 2, Int(month) != nil else { return nil }

        // UTC, matching how the browse tree and the timeline buckets are built.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: newDate)
        guard let newYear = parts.year, let newMonth = parts.month else { return nil }

        let newYearComponent = String(format: "%04d", newYear)
        let newMonthComponent = String(format: "%02d", newMonth)
        guard newYearComponent != year || newMonthComponent != month else { return nil }

        return yearDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(newYearComponent, isDirectory: true)
            .appendingPathComponent(newMonthComponent, isDirectory: true)
            .appendingPathComponent(filename)
            .path
    }

    /// Moves the file, returning where it actually landed.
    ///
    /// Never overwrites: a name already taken in the destination month gets a
    /// `-2` suffix, the same way the browse tree resolves collisions. Two photos
    /// called IMG_0001.jpg from different months are completely ordinary.
    static func move(from: String, to: String, logger: Logger) -> String? {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: from)
        var destination = URL(fileURLWithPath: to)

        guard fm.fileExists(atPath: source.path) else {
            logger.warning("re-time: \(from) is not there to move")
            return nil
        }

        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination.path) {
                let base = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension
                let directory = destination.deletingLastPathComponent()
                var suffix = 2
                repeat {
                    let candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                    destination = directory.appendingPathComponent(candidate)
                    suffix += 1
                } while fm.fileExists(atPath: destination.path) && suffix < 100
            }
            try fm.moveItem(at: source, to: destination)
            return destination.path
        } catch {
            // The database already says the new date. A file that failed to
            // move is found again by `rebuild`, so this is loud but not fatal.
            logger.error("re-time: could not move \(from) to \(to): \(error)")
            return nil
        }
    }
}
