import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// Wakes a phone that still has photographs to send.
///
/// The problem it exists for. A backup runs inside the windows iOS grants a
/// `BGProcessingTask`, and iOS grants them on its own schedule — typically
/// overnight on charge, sometimes not for the better part of a day. So a first
/// backup of several thousand photographs arrives in stops and starts across
/// days, and the person watching it fill has every reason to think the app has
/// given up. This is the gap against Synology's design, which has had a silent
/// push for exactly this since the beginning.
///
/// A `content-available` push asks iOS for background time directly, and iOS is
/// markedly more willing to grant that than to bring a scheduled window forward.
/// It is still a request rather than a command — Apple may delay it, coalesce
/// several into one, or drop it on a device low on power, and none of that is
/// reported back. The design has to be sound when the push simply never
/// arrives, which it is: nothing here is required for a backup to complete, and
/// the scheduled windows carry on underneath.
///
/// What it costs, and why the restraint. Apple meters background pushes to a
/// small number an hour per device and deprioritises apps that spend them on
/// nothing. Three things keep this honest:
///
///   * a device is only a candidate if it *said* it has work outstanding,
///   * it is left alone while an upload is actually arriving,
///   * and each device gets a handful of attempts before it is dropped until it
///     next reports in — so answering a nudge buys more, and silence does not.
///
/// Modelled on `ActivitySweeper`, down to claiming rows with `SKIP LOCKED` so a
/// second server process, or a restart mid-send, cannot double-spend a budget
/// that is measured per device.
actor BackupNudger {
    private let app: Application
    private let apns: APNsClient
    /// How long a device must have been quiet before a nudge is worth spending.
    private let quietSeconds: Int
    /// The minimum gap between two nudges to the same device.
    private let cooldownSeconds: Int
    /// How many unanswered nudges a device gets before it is left alone.
    private let maxNudges: Int
    /// How stale a report can be and still be believed.
    private let reportTTLHours: Int
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(app: Application, apns: APNsClient) {
        self.app = app
        self.apns = apns
        // All tunable so the smoke tests don't have to wait out real windows.
        self.quietSeconds = Environment.get("FRAMESTATION_BACKUP_QUIET_SECONDS")
            .flatMap(Int.init) ?? 900
        self.cooldownSeconds = Environment.get("FRAMESTATION_BACKUP_NUDGE_COOLDOWN_SECONDS")
            .flatMap(Int.init) ?? 1800
        self.maxNudges = Environment.get("FRAMESTATION_BACKUP_NUDGE_LIMIT")
            .flatMap(Int.init) ?? 6
        self.reportTTLHours = Environment.get("FRAMESTATION_BACKUP_REPORT_TTL_HOURS")
            .flatMap(Int.init) ?? 72
        let tick = Environment.get("FRAMESTATION_BACKUP_NUDGE_SECONDS")
            .flatMap(Int.init) ?? 120
        self.interval = .seconds(max(1, tick))
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runLogging()
                try? await Task.sleep(for: self?.interval ?? .seconds(120))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func runLogging() async {
        do {
            try await nudge()
        } catch {
            app.logger.error("backup nudge failed: \(String(reflecting: error))")
        }
    }

    private struct Candidate: Decodable {
        let deviceID: UUID
        let apnsToken: String
        let apnsEnv: String?
        let backupPending: Int
    }

    /// Claims every device worth waking, then wakes them.
    ///
    /// The claim and the send are one step and two statements for the same
    /// reason the sweeper's are: the UPDATE is what stops a second process
    /// picking the same device, and it has to happen before the push rather than
    /// after, because a crash between the two should cost a nudge rather than
    /// hand out an unbounded number of them.
    ///
    /// Conditions, in the order they matter:
    ///
    ///   * the device has a token, and is a phone or an iPad — a Mac has no
    ///     background windows to be rescued from,
    ///   * it reported outstanding work, recently enough to still be true,
    ///   * nothing has arrived from it for a while, so a backup that is already
    ///     running is never interrupted to be told to run,
    ///   * the last nudge is far enough behind us,
    ///   * and it has not already had its share.
    func nudge() async throws {
        let sql = app.sql
        let claimed = try await sql.raw("""
            WITH candidates AS (
                SELECT d.id FROM devices d
                WHERE d.apns_token IS NOT NULL
                  AND d.platform IN ('ios', 'ipados')
                  AND d.backup_pending > 0
                  AND d.backup_nudges < \(bind: maxNudges)
                  AND d.backup_reported_at > now()
                      - (\(bind: reportTTLHours) * interval '1 hour')
                  AND d.backup_reported_at < now()
                      - (\(bind: quietSeconds) * interval '1 second')
                  AND (d.last_seen_at IS NULL OR d.last_seen_at < now()
                      - (\(bind: quietSeconds) * interval '1 second'))
                  AND (d.backup_nudged_at IS NULL OR d.backup_nudged_at < now()
                      - (\(bind: cooldownSeconds) * interval '1 second'))
                  AND NOT EXISTS (
                      SELECT 1 FROM upload_sessions u
                      WHERE u.device_id = d.id
                        AND u.committed_at IS NULL
                        AND u.updated_at > now()
                            - (\(bind: quietSeconds) * interval '1 second')
                  )
                ORDER BY d.backup_reported_at
                FOR UPDATE SKIP LOCKED
                LIMIT 100
            )
            UPDATE devices d
            SET backup_nudged_at = now(), backup_nudges = d.backup_nudges + 1
            FROM candidates
            WHERE d.id = candidates.id
            RETURNING d.id AS "deviceID", d.apns_token AS "apnsToken",
                      d.apns_env AS "apnsEnv", d.backup_pending AS "backupPending"
            """).all(decoding: Candidate.self)

        for candidate in claimed {
            await send(to: candidate, on: sql)
        }
    }

    private func send(to candidate: Candidate, on sql: any SQLDatabase) async {
        let environment = APNSEnvironment(rawValue: candidate.apnsEnv ?? "sandbox") ?? .sandbox
        // The payload says only what it is. The count is deliberately left out:
        // by the time this lands the phone's own queue is the truth, and a stale
        // number in a push is a number somebody will eventually trust.
        let notification = APNsClient.Notification.silent(
            custom: [PushPayloadKey.kind: PushPayloadKey.kindBackup]
        )

        switch await apns.send(notification, to: candidate.apnsToken, environment: environment) {
        case .delivered:
            app.logger.info("""
                nudged device \(candidate.deviceID) — \(candidate.backupPending) \
                item\(candidate.backupPending == 1 ? "" : "s") outstanding
                """)
        case .unregistered:
            // The app is gone from that device. Drop the token and the backlog
            // with it, or this device stays a candidate for ever.
            try? await sql.raw("""
                UPDATE devices
                SET apns_token = NULL, apns_env = NULL, backup_pending = 0
                WHERE id = \(bind: candidate.deviceID)
                """).run()
        case .failed(let reason):
            app.logger.warning("backup nudge failed for \(candidate.deviceID): \(reason)")
        }
    }
}

struct BackupNudgerKey: StorageKey {
    typealias Value = BackupNudger
}
