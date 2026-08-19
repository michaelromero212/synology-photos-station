import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension EditCaptureTimeRequest: @retroactive Content {}
extension RotateMediaRequest: @retroactive Content {}
extension MediaEditResponse: @retroactive Content {}
extension SetCreditRequest: @retroactive Content {}
extension MoveAssetsRequest: @retroactive Content {}
extension MoveAssetsResponse: @retroactive Content {}

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
        protected.post("spaces", ":spaceID", "assets", "move", use: move)
    }

    private struct SpaceRow: Decodable {
        let id: UUID
        let name: String
        let kind: String
    }

    /// Moves photos out of this space and into another.
    ///
    /// A move rather than a copy, which makes it the one edit here that changes
    /// where the *file* lives as well as what the database says. Both have to
    /// agree or the two halves of this system start describing different
    /// libraries — the app showing a photo in one place and File Station showing
    /// it in another is exactly the confusion the canonical-file layout exists
    /// to prevent.
    ///
    /// Order matters. The file is relocated first and the rows are updated after,
    /// inside a transaction: if the move fails the rows never change, and a photo
    /// stays wholly in the space it started in. The reverse order can leave a
    /// database pointing at a path with nothing on the end of it.
    ///
    /// Destination must be a shared space you can contribute to. Moving *into*
    /// someone's personal library would put your photos in their private tree,
    /// which is not a thing one member of a household should be able to do to
    /// another.
    @Sendable
    func move(req: Request) async throws -> MoveAssetsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(MoveAssetsRequest.self)
        guard !input.assetIDs.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to move.")
        }
        guard input.assetIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Move at most 500 items at once.")
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
            throw Abort(.forbidden, reason: "Photos can only be moved into a shared space.")
        }

        let configuration = BrowseTree.Configuration.fromEnvironment()
        var movedIDs: [UUID] = []

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                for assetID in input.assetIDs {
                    guard let target = try await Self.target(
                        assetID: assetID, spaceID: sourceID, on: sql
                    ) else { continue }

                    // Where the file should end up. Nil when the browse tree is
                    // off, or when the destination can't be resolved — the rows
                    // still move, because the database is the library and the
                    // tree is a mirror of it.
                    var relocated: String?
                    if let current = target.storagePath, !current.isEmpty,
                       let sha256 = target.sha256 {
                        let placement = BrowseTree.Placement(
                            id: target.placementID,
                            sha256: sha256,
                            blobExt: (current as NSString).pathExtension,
                            filename: target.filename,
                            capturedAt: target.capturedAt,
                            spaceKind: destination.kind,
                            spaceName: destination.name,
                            dsmUsername: nil,
                            dsmUID: nil
                        )
                        if let wanted = BrowseTree.destination(
                            for: placement, configuration: configuration
                        ) {
                            // Same collision rule the worker uses when it first
                            // writes a file, so a move can't quietly overwrite
                            // a different photo that happens to share a name.
                            let path = BrowseTreeWorker.deduplicated(wanted, sha256: sha256)
                            try FileManager.default.createDirectory(
                                atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true
                            )
                            try FileManager.default.moveItem(atPath: current, toPath: path)
                            relocated = path
                        }
                    }

                    try await sql.raw("""
                        UPDATE space_assets SET space_id = \(bind: destination.id)
                        WHERE id = \(bind: target.placementID)
                        """).run()
                    if let relocated {
                        try await sql.raw("""
                            UPDATE assets SET storage_path = \(bind: relocated)
                            WHERE id = \(bind: assetID)
                            """).run()
                    }

                    // Both spaces are told: it left one and arrived in the
                    // other, so anyone looking at either sees it happen without
                    // a refresh.
                    _ = try await ChangeLog.append(
                        spaceID: sourceID, entity: "space_asset",
                        entityID: target.placementID, op: "delete", on: sql
                    )
                    _ = try await ChangeLog.append(
                        spaceID: destination.id, entity: "space_asset",
                        entityID: target.placementID, op: "insert", on: sql
                    )
                    movedIDs.append(assetID)
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        return MoveAssetsResponse(
            moved: movedIDs.count,
            assetIDs: movedIDs,
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
