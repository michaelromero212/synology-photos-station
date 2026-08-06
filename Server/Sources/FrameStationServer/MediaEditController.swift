import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension EditCaptureTimeRequest: @retroactive Content {}
extension RotateMediaRequest: @retroactive Content {}
extension MediaEditResponse: @retroactive Content {}

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
        try await sql.raw("""
            SELECT sa.id AS "placementID", a.captured_at AS "capturedAt",
                   a.storage_path AS "storagePath", a.filename, a.sha256,
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
