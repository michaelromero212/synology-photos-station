import Foundation
import FrameStationAPI
import SQLKit
import Vapor

enum SpaceAccess {
    private struct RoleRow: Decodable { let role: String }

    /// Confirms the user belongs to the space, returning their role.
    ///
    /// 404 rather than 403 on a non-member: whether a given space exists is
    /// itself information a non-member shouldn't get.
    @discardableResult
    static func requireMembership(
        spaceID: UUID,
        userID: UUID,
        on sql: any SQLDatabase
    ) async throws -> SpaceRole {
        guard let row = try await sql.raw("""
            SELECT role FROM space_members
            WHERE space_id = \(bind: spaceID) AND user_id = \(bind: userID)
            """).first(decoding: RoleRow.self)
        else {
            throw Abort(.notFound, reason: "No such space.")
        }
        return SpaceRole(rawValue: row.role) ?? .viewer
    }

    static func requireContributor(
        spaceID: UUID,
        userID: UUID,
        on sql: any SQLDatabase
    ) async throws {
        let role = try await requireMembership(spaceID: spaceID, userID: userID, on: sql)
        guard role != .viewer else {
            throw Abort(.forbidden, reason: "You have view-only access to this space.")
        }
    }
}

enum ChangeLog {
    private struct SeqRow: Decodable { let seq: Int64 }

    /// Appends a change_log entry and returns its sequence number.
    ///
    /// **Must be called inside a transaction.** `bigserial` values are assigned
    /// at INSERT, not COMMIT, so two concurrent writers can commit out of
    /// sequence order — a client polling `since=N` would then permanently miss
    /// the row that committed late. The advisory lock serializes sequence
    /// assignment and commit per space, which closes that hole. Contention is
    /// irrelevant at four users. See ARCHITECTURE.md §5.
    static func append(
        spaceID: UUID,
        entity: String,
        entityID: UUID,
        op: String,
        on sql: any SQLDatabase
    ) async throws -> Int64 {
        try await sql.raw(
            "SELECT pg_advisory_xact_lock(hashtext(\(bind: spaceID.uuidString))::bigint)"
        ).run()

        guard let row = try await sql.raw("""
            INSERT INTO change_log (space_id, entity, entity_id, op)
            VALUES (\(bind: spaceID), \(bind: entity), \(bind: entityID), \(bind: op))
            RETURNING seq
            """).first(decoding: SeqRow.self)
        else {
            throw Abort(.internalServerError, reason: "Could not record change.")
        }
        return row.seq
    }
}

enum ActivityTracker {
    /// Rolls uploads up into a per-(space, user) session so M6 can send one
    /// "Morgan added 10 photos and 2 videos" push instead of twelve.
    ///
    /// A session stays open while uploads keep arriving; the M6 sweeper closes
    /// it after five idle minutes and sends a single notification. `is_bulk`
    /// trips past 200 items so an initial device backup collapses to one
    /// summary rather than notifying the family about 8,000 photos.
    static func record(
        spaceID: UUID,
        userID: UUID,
        mediaType: MediaType,
        on sql: any SQLDatabase
    ) async throws {
        let photoDelta = mediaType == .photo ? 1 : 0
        let videoDelta = mediaType == .video ? 1 : 0

        try await sql.raw("""
            INSERT INTO activity_sessions (space_id, user_id, photo_count, video_count)
            VALUES (\(bind: spaceID), \(bind: userID), \(bind: photoDelta), \(bind: videoDelta))
            ON CONFLICT (space_id, user_id) WHERE closed_at IS NULL
            DO UPDATE SET
                photo_count = activity_sessions.photo_count + \(bind: photoDelta),
                video_count = activity_sessions.video_count + \(bind: videoDelta),
                last_at     = now(),
                is_bulk     = (activity_sessions.photo_count + activity_sessions.video_count + 1) > 200
            """).run()
    }
}
