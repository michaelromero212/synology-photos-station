import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// Turns batched upload activity into one notification per burst.
///
/// The batching is the point. A phone finishing its evening backup writes forty
/// rows in ninety seconds, and forty notifications would make the family turn
/// them off for good. An `activity_session` accumulates counts while uploads
/// keep arriving; this sweeper closes it once it has been quiet for a few
/// minutes and sends a single summary.
///
/// There is no "the user is finished" signal to wait for and there can't be —
/// the phone that would send it is the one being backgrounded, killed and
/// relaunched throughout. So a burst is judged over rather than announced over,
/// and `sweep()` is where that judgement lives.
actor ActivitySweeper {
    private let app: Application
    private let apns: APNsClient
    private let idleWindow: Int
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(app: Application, apns: APNsClient) {
        self.app = app
        self.apns = apns
        // Tunable so the smoke tests don't have to wait five real minutes.
        self.idleWindow = Environment.get("FRAMESTATION_ACTIVITY_IDLE_SECONDS")
            .flatMap(Int.init) ?? 300
        let tick = Environment.get("FRAMESTATION_ACTIVITY_SWEEP_SECONDS")
            .flatMap(Int.init) ?? 30
        self.interval = .seconds(max(1, tick))
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepLogging()
                try? await Task.sleep(for: self?.interval ?? .seconds(30))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sweepLogging() async {
        do {
            try await sweep()
        } catch {
            app.logger.error("activity sweep failed: \(String(reflecting: error))")
        }
    }

    private struct ClosedSession: Decodable {
        let id: UUID
        let spaceID: UUID
        let userID: UUID
        let photoCount: Int
        let videoCount: Int
        let isBulk: Bool
        let spaceName: String
        let spaceKind: String
        let uploaderName: String
    }

    private struct Recipient: Decodable {
        let deviceID: UUID
        let apnsToken: String
        let apnsEnv: String?
    }

    /// Claims every session that has gone quiet, then notifies for each.
    ///
    /// Closing and notifying are separate steps on purpose: the UPDATE marks the
    /// session so a second sweeper (or a restart mid-send) cannot pick it up
    /// again, and `notified_at` records that the push actually went out.
    ///
    /// "Quiet" has to mean two things, and for a while it only meant one.
    /// `last_at` moves when an asset *finalises*, and the backup queue uploads
    /// strictly one item at a time — so somebody who adds ten photos and then a
    /// 4 GB video goes silent by this measure for as long as the video takes.
    /// The session closed mid-batch and the family got "Morgan added 10 photos",
    /// then a second push for the video once it landed. One sitting, two
    /// notifications, which is the exact thing the sweeper exists to prevent.
    ///
    /// So a session is also held open while its owner has an upload still in
    /// flight into that space. `upload_sessions.updated_at` is bumped on every
    /// chunk received, which makes it a heartbeat: a live transfer keeps it
    /// moving, and an abandoned one — force-quit mid-video — goes stale on its
    /// own. Judging that staleness by the *same* idle window is what keeps this
    /// from needing a second knob, and what stops one dead upload holding a
    /// notification open forever.
    func sweep() async throws {
        let sql = app.sql
        let closed = try await sql.raw("""
            WITH claimed AS (
                SELECT id FROM activity_sessions a
                WHERE a.closed_at IS NULL
                  AND a.last_at < now() - (\(bind: idleWindow) * interval '1 second')
                  AND NOT EXISTS (
                      SELECT 1 FROM upload_sessions u
                      WHERE u.user_id = a.user_id
                        AND u.space_id = a.space_id
                        AND u.committed_at IS NULL
                        AND u.updated_at > now() - (\(bind: idleWindow) * interval '1 second')
                  )
                ORDER BY a.last_at
                FOR UPDATE SKIP LOCKED
                LIMIT 50
            )
            UPDATE activity_sessions a SET closed_at = now()
            FROM claimed, spaces s, users u
            WHERE a.id = claimed.id AND s.id = a.space_id AND u.id = a.user_id
            RETURNING a.id, a.space_id AS "spaceID", a.user_id AS "userID",
                      a.photo_count AS "photoCount", a.video_count AS "videoCount",
                      a.is_bulk AS "isBulk", s.name AS "spaceName", s.kind AS "spaceKind",
                      u.display_name AS "uploaderName"
            """).all(decoding: ClosedSession.self)

        for session in closed {
            await notify(session, on: sql)
        }
    }

    private func notify(_ session: ClosedSession, on sql: any SQLDatabase) async {
        // Nobody to tell about your own private library.
        guard session.spaceKind != "personal" else {
            try? await markNotified(session.id, error: nil, on: sql)
            return
        }
        guard session.photoCount + session.videoCount > 0 else {
            try? await markNotified(session.id, error: nil, on: sql)
            return
        }

        let notification = APNsClient.Notification.alert(
            title: session.spaceName,
            body: ActivityMessage.body(
                name: session.uploaderName,
                photos: session.photoCount,
                videos: session.videoCount,
                isBulk: session.isBulk
            ),
            threadID: session.spaceID.uuidString,
            custom: [
                PushPayloadKey.spaceID: session.spaceID.uuidString,
                PushPayloadKey.kind: PushPayloadKey.kindActivity,
            ]
        )

        do {
            // Everyone in the space except whoever did the uploading — being
            // told about your own upload is noise.
            let recipients = try await sql.raw("""
                SELECT d.id AS "deviceID", d.apns_token AS "apnsToken", d.apns_env AS "apnsEnv"
                FROM space_members m
                JOIN devices d ON d.user_id = m.user_id
                WHERE m.space_id = \(bind: session.spaceID)
                  AND m.user_id <> \(bind: session.userID)
                  AND d.apns_token IS NOT NULL
                """).all(decoding: Recipient.self)

            var failure: String?
            for recipient in recipients {
                let environment = APNSEnvironment(rawValue: recipient.apnsEnv ?? "sandbox")
                    ?? .sandbox
                switch await apns.send(
                    notification, to: recipient.apnsToken, environment: environment
                ) {
                case .delivered:
                    continue
                case .unregistered:
                    // The app is gone from that device. Drop the token so the
                    // next sweep doesn't keep trying it forever.
                    try? await sql.raw("""
                        UPDATE devices SET apns_token = NULL, apns_env = NULL
                        WHERE id = \(bind: recipient.deviceID)
                        """).run()
                case .failed(let reason):
                    failure = reason
                    app.logger.warning("push failed for device \(recipient.deviceID): \(reason)")
                }
            }
            try await markNotified(session.id, error: failure, on: sql)
        } catch {
            try? await markNotified(
                session.id, error: String(reflecting: error), on: sql
            )
        }
    }

    private func markNotified(_ id: UUID, error: String?, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE activity_sessions
            SET notified_at = now(), notify_error = \(bind: error)
            WHERE id = \(bind: id)
            """).run()
    }
}

struct ActivitySweeperKey: StorageKey {
    typealias Value = ActivitySweeper
}
