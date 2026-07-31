import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension ActivityFeedResponse: @retroactive Content {}

/// The in-app inbox: who has been adding to the shared spaces you're in.
///
/// Reads the same `activity_sessions` rows the push sweeper closes, so the
/// banner and the inbox always say the same thing — and the feed still works
/// when push is unconfigured or the user declined notifications.
struct ActivityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("activity", use: feed)
        protected.post("activity", "read", use: markRead)
    }

    private struct Row: Decodable {
        let id: UUID
        let spaceID: UUID
        let spaceName: String
        let userID: UUID
        let displayName: String
        let photoCount: Int
        let videoCount: Int
        let isBulk: Bool
        let at: Date
        let isUnread: Bool
    }

    private func feed(_ req: Request) async throws -> ActivityFeedResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)

        // Only shared spaces this user belongs to, and never their own uploads:
        // an inbox that tells you what you just did is noise.
        let rows = try await req.sql.raw("""
            SELECT a.id, a.space_id AS "spaceID", s.name AS "spaceName",
                   a.user_id AS "userID", u.display_name AS "displayName",
                   a.photo_count AS "photoCount", a.video_count AS "videoCount",
                   a.is_bulk AS "isBulk",
                   -- When they last added something, not when the sweeper got
                   -- round to closing it. Those are normally minutes apart, but
                   -- after any server downtime closed_at would report a whole
                   -- backlog as "just now".
                   a.last_at AS "at",
                   (a.closed_at > COALESCE(me.activity_read_at, '-infinity'::timestamptz))
                       AS "isUnread"
            FROM activity_sessions a
            JOIN spaces s ON s.id = a.space_id
            JOIN users u ON u.id = a.user_id
            JOIN space_members m ON m.space_id = a.space_id
            JOIN users me ON me.id = \(bind: device.userID)
            WHERE m.user_id = \(bind: device.userID)
              AND a.user_id <> \(bind: device.userID)
              AND s.kind = 'shared'
              AND a.closed_at IS NOT NULL
              AND a.photo_count + a.video_count > 0
            ORDER BY a.last_at DESC
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)

        let items = rows.map {
            ActivityItemDTO(
                id: $0.id,
                spaceID: $0.spaceID,
                spaceName: $0.spaceName,
                user: UserDTO(id: $0.userID, displayName: $0.displayName),
                photoCount: $0.photoCount,
                videoCount: $0.videoCount,
                isBulk: $0.isBulk,
                at: $0.at,
                isUnread: $0.isUnread
            )
        }
        return ActivityFeedResponse(
            items: items, unreadCount: items.filter(\.isUnread).count
        )
    }

    private func markRead(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        try await req.sql.raw("""
            UPDATE users SET activity_read_at = now() WHERE id = \(bind: device.userID)
            """).run()
        return .noContent
    }
}
