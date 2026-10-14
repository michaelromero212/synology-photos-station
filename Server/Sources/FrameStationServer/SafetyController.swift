import Foundation
import FrameStationAPI
import SQLKit
import Vapor

extension ReportPhotoRequest: @retroactive Content {}
extension ContentReportsResponse: @retroactive Content {}
extension ResolveReportRequest: @retroactive Content {}
extension BlockedUsersResponse: @retroactive Content {}

/// What one person has put out of their own sight: photos they reported, and
/// everything added by someone they blocked.
///
/// Only ever their own view. A report leaves the photo where it is for
/// everyone else until the library's owner decides, and a block changes
/// nothing for anyone but the person who made it.
///
/// Every query that shows a library's photos to a person reads this, so a
/// hidden photo is hidden the same way in the grid, its counts, a day's
/// places, search and albums.
///
/// A block reaches only shared libraries. A photo in your own library is
/// yours whoever it's credited to, and blocking someone shouldn't take your
/// own pictures of them away. Reports can only be made in a shared library,
/// so they need no such rule.
///
/// Shaped for a library of tens of thousands. Reports are an anti-join.
/// Blocks are read once per query into an array, with the person's own
/// library beside them, rather than asked about row by row: written as a
/// second `NOT EXISTS` joined to `spaces`, Postgres ran it once per photo,
/// and on 70,000 photos the grid's manifest went from 51 ms to 86. This way
/// it's 57.
enum Hidden {
    static func excluded(for userID: UUID, placement alias: String = "sa") -> SQLQueryString {
        """
        NOT EXISTS (
            SELECT 1 FROM content_reports cr
            WHERE cr.space_asset_id = \(unsafeRaw: alias).id
              AND cr.reporter_id = \(bind: userID)
        )
        AND (
            COALESCE(\(unsafeRaw: alias).credited_to_user_id, \(unsafeRaw: alias).uploaded_by_user_id)
                <> ALL (ARRAY(
                    SELECT ub.blocked_id FROM user_blocks ub WHERE ub.blocker_id = \(bind: userID)
                ))
            OR \(unsafeRaw: alias).space_id = ANY (ARRAY(
                SELECT hs.id FROM spaces hs
                WHERE hs.kind = 'personal' AND hs.created_by = \(bind: userID)
            ))
        )
        """
    }
}

/// Reporting a photo in a shared library, and blocking a member.
///
/// What the App Store asks of any app where people share with each other: a
/// way to report what shouldn't be there, someone to answer the report, and a
/// way to stop seeing someone. In a family library the one who answers is the
/// library's owner. FrameStation's makers can't see anyone's photos, and
/// that's the point of it.
struct SafetyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.post("spaces", ":spaceID", "reports", use: report)
        protected.get("spaces", ":spaceID", "reports", use: openReports)
        protected.post("spaces", ":spaceID", "reports", ":placementID", "resolve", use: resolve)

        protected.get("blocks", use: blocks)
        protected.put("blocks", ":userID", use: block)
        protected.delete("blocks", ":userID", use: unblock)
    }

    // MARK: - Reports

    private struct PlacementRow: Decodable {
        let id: UUID
        let kind: String
        let spaceName: String
        let addedBy: UUID
    }

    /// Reports one photo: hidden from the reporter at once, and the library's
    /// owner told. Reporting again replaces the reason and opens it again.
    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(ReportPhotoRequest.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        guard let placement = try await req.sql.raw("""
            SELECT sa.id, s.kind, s.name AS "spaceName",
                   COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "addedBy"
            FROM space_assets sa
            JOIN spaces s ON s.id = sa.space_id
            WHERE sa.id = \(bind: input.placementID) AND sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
            """).first(decoding: PlacementRow.self) else {
            throw Abort(.notFound, reason: "No such photo in this library.")
        }
        guard placement.kind == SpaceKind.shared.rawValue else {
            throw Abort(.badRequest, reason: "Only photos in a shared library can be reported.")
        }
        guard placement.addedBy != device.userID else {
            throw Abort(.badRequest, reason: "You added this one. Remove it instead.")
        }

        try await req.sql.raw("""
            INSERT INTO content_reports (space_asset_id, reporter_id, reason)
            VALUES (\(bind: placement.id), \(bind: device.userID), \(bind: input.reason.rawValue))
            ON CONFLICT (space_asset_id, reporter_id) DO UPDATE
            SET reason = EXCLUDED.reason, created_at = now(),
                resolved_at = NULL, resolved_by = NULL, outcome = NULL
            """).run()

        // Told in the background: the report is recorded either way, and the
        // person reporting shouldn't wait on Apple's servers to be told so.
        let app = req.application
        Task {
            await Self.tellOwners(
                spaceID: spaceID, spaceName: placement.spaceName,
                reporterID: device.userID, app: app
            )
        }
        req.logger.info("photo reported in space \(spaceID)")
        return .noContent
    }

    private struct Recipient: Decodable {
        let apnsToken: String
        let apnsEnv: String?
    }

    /// A push to the library's owner, wherever they're signed in. Not to the
    /// reporter, when the owner reports something themselves.
    ///
    /// It doesn't say who reported it, and neither does the list the owner
    /// reviews. In a family, a report someone has to put their name to is one
    /// they often won't make.
    private static func tellOwners(
        spaceID: UUID, spaceName: String, reporterID: UUID, app: Application
    ) async {
        guard let apns = app.storage[APNsClientKey.self] else { return }
        do {
            let recipients = try await app.sql.raw("""
                SELECT d.apns_token AS "apnsToken", d.apns_env AS "apnsEnv"
                FROM space_members m
                JOIN devices d ON d.user_id = m.user_id
                WHERE m.space_id = \(bind: spaceID)
                  AND m.role = 'owner'
                  AND m.user_id <> \(bind: reporterID)
                  AND d.apns_token IS NOT NULL
                """).all(decoding: Recipient.self)
            let notification = APNsClient.Notification.alert(
                title: spaceName,
                body: "Someone reported a photo here. Tap to review it.",
                threadID: spaceID.uuidString,
                custom: [
                    PushPayloadKey.spaceID: spaceID.uuidString,
                    PushPayloadKey.kind: PushPayloadKey.kindReport,
                ]
            )
            for recipient in recipients {
                _ = await apns.send(
                    notification, to: recipient.apnsToken,
                    environment: APNSEnvironment(rawValue: recipient.apnsEnv ?? "sandbox")
                        ?? .sandbox
                )
            }
        } catch {
            app.logger.warning("couldn't tell the owner about a report: \(error)")
        }
    }

    private struct ReportRow: Decodable {
        let placementID: UUID
        let assetID: UUID
        let mediaType: String
        let reasons: [String]
        let reportCount: Int
        let addedByName: String
        let reportedAt: Date
    }

    /// The photos waiting on this library's owner, most recently reported
    /// first: one entry a photo, however many people reported it. Owners only.
    @Sendable
    func openReports(req: Request) async throws -> ContentReportsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await Self.requireOwner(spaceID: spaceID, userID: device.userID, on: req.sql)

        let rows = try await req.sql.raw("""
            SELECT sa.id AS "placementID", sa.asset_id AS "assetID",
                   a.media_type AS "mediaType",
                   array_agg(cr.reason ORDER BY cr.created_at DESC) AS reasons,
                   count(*)::int AS "reportCount",
                   added.display_name AS "addedByName",
                   max(cr.created_at) AS "reportedAt"
            FROM content_reports cr
            JOIN space_assets sa ON sa.id = cr.space_asset_id
            JOIN assets a ON a.id = sa.asset_id
            JOIN users added
              ON added.id = COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id)
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND cr.resolved_at IS NULL
            GROUP BY sa.id, sa.asset_id, a.media_type, added.display_name
            ORDER BY max(cr.created_at) DESC
            """).all(decoding: ReportRow.self)

        return ContentReportsResponse(reports: rows.map {
            ContentReportDTO(
                id: $0.placementID, assetID: $0.assetID,
                mediaType: MediaType(rawValue: $0.mediaType) ?? .photo,
                reasons: Self.distinct($0.reasons),
                reportCount: $0.reportCount,
                addedByName: $0.addedByName, reportedAt: $0.reportedAt
            )
        })
    }

    /// Each reason once, in the order first given.
    private static func distinct(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// Closes every open report of one photo: the owner kept it, or took it
    /// out — which the app does through the ordinary remove first, so a Live
    /// Photo's motion and every device's grid go with it the way any removal's
    /// do. Owners only.
    ///
    /// Kept or not, it stays hidden from whoever reported it. The owner's
    /// decision is about the library, not about what one person has said they
    /// don't want to see.
    @Sendable
    func resolve(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let placementID = try req.parameters.require("placementID", as: UUID.self)
        let input = try req.content.decode(ResolveReportRequest.self)
        try await Self.requireOwner(spaceID: spaceID, userID: device.userID, on: req.sql)

        struct Closed: Decodable { let id: UUID }
        let closed = try await req.sql.raw("""
            UPDATE content_reports cr
            SET resolved_at = now(), resolved_by = \(bind: device.userID),
                outcome = \(bind: input.outcome.rawValue)
            FROM space_assets sa
            WHERE sa.id = cr.space_asset_id
              AND sa.space_id = \(bind: spaceID)
              AND cr.space_asset_id = \(bind: placementID)
              AND cr.resolved_at IS NULL
            RETURNING cr.id
            """).all(decoding: Closed.self)
        guard !closed.isEmpty else {
            throw Abort(.notFound, reason: "Nothing reported to review there.")
        }
        return .noContent
    }

    private static func requireOwner(
        spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws {
        let role = try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: userID, on: sql
        )
        guard role == .owner else {
            throw Abort(.forbidden, reason: "Only the library's owner can review reports.")
        }
    }

    // MARK: - Blocks

    private struct BlockedRow: Decodable {
        let id: UUID
        let displayName: String
        let blockedAt: Date
    }

    @Sendable
    func blocks(req: Request) async throws -> BlockedUsersResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let rows = try await req.sql.raw("""
            SELECT u.id, u.display_name AS "displayName", b.created_at AS "blockedAt"
            FROM user_blocks b
            JOIN users u ON u.id = b.blocked_id
            WHERE b.blocker_id = \(bind: device.userID)
            ORDER BY u.display_name
            """).all(decoding: BlockedRow.self)
        return BlockedUsersResponse(users: rows.map {
            BlockedUserDTO(id: $0.id, displayName: $0.displayName, blockedAt: $0.blockedAt)
        })
    }

    /// Blocks someone this person shares a library with. Anyone else is a
    /// 404, the same as a person who doesn't exist: who has an account on the
    /// NAS isn't something a member should be able to find out by guessing.
    @Sendable
    func block(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let target = try req.parameters.require("userID", as: UUID.self)
        guard target != device.userID else {
            throw Abort(.badRequest, reason: "You can't block yourself.")
        }

        // Someone in a library with them, or whose photos are still in one:
        // a member who has left, or deleted their account, leaves what they
        // added behind.
        struct Shared: Decodable { let shared: Bool }
        let shares = try await req.sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM space_members mine
                JOIN space_members theirs ON theirs.space_id = mine.space_id
                WHERE mine.user_id = \(bind: device.userID)
                  AND theirs.user_id = \(bind: target)
            ) OR EXISTS (
                SELECT 1 FROM space_members mine
                JOIN spaces s ON s.id = mine.space_id AND s.kind = 'shared'
                JOIN space_assets sa ON sa.space_id = mine.space_id
                WHERE mine.user_id = \(bind: device.userID)
                  AND sa.deleted_at IS NULL
                  AND COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) = \(bind: target)
            ) AS shared
            """).first(decoding: Shared.self)
        guard shares?.shared == true else {
            throw Abort(.notFound, reason: "No such person.")
        }

        try await req.sql.raw("""
            INSERT INTO user_blocks (blocker_id, blocked_id)
            VALUES (\(bind: device.userID), \(bind: target))
            ON CONFLICT DO NOTHING
            """).run()
        return .noContent
    }

    @Sendable
    func unblock(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let target = try req.parameters.require("userID", as: UUID.self)
        try await req.sql.raw("""
            DELETE FROM user_blocks
            WHERE blocker_id = \(bind: device.userID) AND blocked_id = \(bind: target)
            """).run()
        return .noContent
    }
}

/// The push client, for a request that has something to tell someone. See
/// `Configure`.
struct APNsClientKey: StorageKey {
    typealias Value = APNsClient
}
