import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// Feeds the analyzer container one file at a time and stores its answers.
/// See NAS-ANALYSIS.md.
///
/// The server is the only writer. The worker picks files from the personal
/// libraries of people enrolled (`users.nas_analysis`) who have curation on:
/// new uploads first, then the library newest to oldest. A file waits until
/// its thumbnails are made, which is also what keeps this behind the
/// derivation queue. The analyzer runs one request at a time, at the lowest
/// CPU priority, in a container of its own, so this loop never needs to pace
/// itself: the app's requests always come first.
///
/// When the analyzer is missing, stopped or crashing, the server is
/// unaffected. This logs once, backs off, and carries on when it's back.
///
/// Logs carry counts, timings and a hash prefix, never a path or anything
/// about what a file shows.
actor AnalysisWorker {
    static let batchSize = 50
    /// A file that fails is tried this many times, six hours apart.
    static let maxAttempts = 3

    private let app: Application
    private let client: AnalyzerClient
    private let seal: FaceSeal
    /// Turns each file's scene into labels and tags as soon as it's stored.
    private let scorer: NASScorer?
    private let startDelay: Duration
    private let idle: Duration
    private var task: Task<Void, Never>?

    /// What was last said in the log about the analyzer, so a state is
    /// announced once rather than on every retry.
    private var announced: String?
    private var window = Window()
    /// Files in a row the analyzer couldn't find or read. One is that file;
    /// ten in a row is a mount, and analysis pauses rather than marking the
    /// whole library failed.
    private var missesInARow = 0
    static let missesBeforePausing = 10
    /// The file the analyzer last went quiet on, and how many times in a row.
    private var strikes: (key: String, count: Int)?
    static let crashesBeforeSettingAside = 3

    private struct Window {
        var analyzed = 0
        var skipped = 0
        var failed = 0
        var started = ContinuousClock.now
    }

    /// `startDelay` lets a booting server settle first; `idle` is how often
    /// it looks again when there's nothing to do. The smoke tests shorten both.
    init(
        app: Application, client: AnalyzerClient, seal: FaceSeal, scorer: NASScorer? = nil,
        startDelay: Duration = .seconds(30), idle: Duration = .seconds(30)
    ) {
        self.app = app
        self.client = client
        self.seal = seal
        self.scorer = scorer
        self.startDelay = startDelay
        self.idle = idle
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - The loop

    /// The analyzer can't read file after file where the server keeps them.
    /// A mount is wrong, not the files, so nothing more is recorded.
    private struct Paused: Error {
        let code: String
    }

    private func run() async {
        try? await Task.sleep(for: startDelay)
        var backoff: Duration = .seconds(10)
        while !Task.isCancelled {
            do {
                let health = try await client.health()
                guard health.status == "ok", health.protocol == AnalyzerClient.protocolVersion else {
                    announce("analysis: the analyzer speaks protocol \(health.protocol), this server \(AnalyzerClient.protocolVersion); waiting for matching versions")
                    try? await Task.sleep(for: .seconds(600))
                    continue
                }
                announce("analysis: analyzer ready, version \(health.analyzer), \(health.threads) threads, \(health.modelSummary)")
                backoff = .seconds(10)

                let batch = try await candidates(version: health.analyzer)
                if batch.isEmpty {
                    await report(version: health.analyzer, force: true)
                    try? await Task.sleep(for: idle)
                    continue
                }
                for item in batch {
                    if Task.isCancelled { return }
                    try await process(item, health: health)
                }
                await report(version: health.analyzer, force: false)
            } catch is CancellationError {
                return
            } catch let paused as Paused {
                announce("analysis paused: the analyzer can't read the files where the server keeps them (\(paused.code)). Check its read-only mounts in docker-compose.yml.")
                try? await Task.sleep(for: .seconds(600))
            } catch AnalyzerClient.Failure.unreachable(let why) {
                announce("analysis: the analyzer isn't answering (\(why)); trying again with backoff")
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
            } catch {
                app.logger.error("analysis: \(String(reflecting: error))")
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func announce(_ line: String) {
        guard line != announced else { return }
        announced = line
        app.logger.notice("\(line)")
    }

    // MARK: - One file

    private struct Candidate: Decodable {
        let userID: UUID
        let sha256: String
        let mediaType: String
        let blobExt: String
        let storagePath: String?
        /// People on: faces are kept with their templates. Off, only where
        /// they are. See `CurationController.setPeople`.
        let peopleEnabled: Bool
    }

    private func process(_ item: Candidate, health: AnalyzerClient.Health) async throws {
        let kind = MediaType(rawValue: item.mediaType) ?? .photo
        // The library copy when there is one, the blob otherwise, as every
        // other reader does. See ARCHITECTURE.md §3a.
        let path: String
        if let library = item.storagePath, FileManager.default.fileExists(atPath: library) {
            path = library
        } else {
            path = app.blobStore.blobPath(sha256: item.sha256, fileExtension: item.blobExt).path
        }
        guard FileManager.default.fileExists(atPath: path) else {
            try await record(item, status: "failed", code: "missing-file", health: health)
            return
        }

        let key = "\(item.userID)|\(item.sha256)"
        do {
            let analysis: AnalyzerClient.Analysis
            do {
                analysis = try await client.analyze(path: path, kind: kind, faces: true)
            } catch AnalyzerClient.Failure.unreachable(let why) {
                // The analyzer answered its health check as this batch began,
                // so going quiet on this file may mean the file took it down:
                // a decoder crash, or more memory than its cap. Asked for again
                // after every restart, such a file would come first forever.
                // Three times in a row and it's set aside.
                let count = (strikes?.key == key ? strikes?.count ?? 0 : 0) + 1
                strikes = (key, count)
                guard count >= Self.crashesBeforeSettingAside else {
                    throw AnalyzerClient.Failure.unreachable(why)
                }
                strikes = nil
                app.logger.notice("analysis: set aside \(item.sha256.prefix(8)), which the analyzer stopped on \(count) times in a row")
                try await record(item, status: "failed", code: "analyzer-stopped", health: health)
                return
            }
            if strikes?.key == key { strikes = nil }
            // A long analysis can outlast the server: once it's shutting down,
            // the database is no longer there to write to.
            try Task.checkCancellation()
            do {
                try await save(item, analysis)
            } catch {
                // Recorded, so one file the database won't take can't hold up
                // every file after it.
                app.logger.error("analysis: couldn't store \(item.sha256.prefix(8)): \(String(reflecting: error))")
                try await record(item, status: "failed", code: "store", health: health)
                return
            }
            missesInARow = 0
            window.analyzed += 1
            await scorer?.score(userID: item.userID, sha256: item.sha256)
            app.logger.debug("analysis: \(item.sha256.prefix(8)) \(kind.rawValue), \(analysis.frames) frame(s), \(analysis.durationMS) ms")
        } catch AnalyzerClient.Failure.rejected(let code) {
            switch code {
            case "outside-roots", "unreadable", "not-found":
                missesInARow += 1
                if missesInARow >= Self.missesBeforePausing {
                    missesInARow = 0
                    throw Paused(code: code)
                }
                try await record(item, status: "failed", code: code, health: health)
            case "unsupported", "too-large", "not-a-file":
                try await record(item, status: "skipped", code: code, health: health)
            default:
                try await record(item, status: "failed", code: code, health: health)
            }
        } catch AnalyzerClient.Failure.status(let status) {
            try await record(item, status: "failed", code: "status-\(status)", health: health)
        } catch AnalyzerClient.Failure.malformed {
            try await record(item, status: "failed", code: "malformed", health: health)
        }
    }

    private func save(_ item: Candidate, _ analysis: AnalyzerClient.Analysis) async throws {
        // Sealed before the transaction, so nothing slow happens inside it.
        // With People off, no template is kept: only where each face is.
        var faces: [(ordinal: Int, face: AnalyzerClient.Face, sealed: Data?)] = []
        for (ordinal, face) in analysis.faces.enumerated() {
            let sealed = item.peopleEnabled
                ? try seal.seal(face.embedding, userID: item.userID, sha256: item.sha256, ordinal: ordinal)
                : nil
            faces.append((ordinal, face, sealed))
        }
        let userID = item.userID, sha256 = item.sha256, sealedFaces = faces
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    INSERT INTO nas_analysis
                        (user_id, sha256, analyzer_version, models, status, error, attempts,
                         frames, scene, face_count, duration_ms, analyzed_at)
                    VALUES (\(bind: userID), \(bind: sha256), \(bind: analysis.analyzer),
                            \(bind: analysis.models), 'done', NULL, 1,
                            \(bind: analysis.frames), \(bind: analysis.scene),
                            \(bind: analysis.faces.count), \(bind: analysis.durationMS), now())
                    ON CONFLICT (user_id, sha256) DO UPDATE SET
                        analyzer_version = EXCLUDED.analyzer_version, models = EXCLUDED.models,
                        status = 'done', error = NULL, attempts = 1, frames = EXCLUDED.frames,
                        scene = EXCLUDED.scene, face_count = EXCLUDED.face_count,
                        duration_ms = EXCLUDED.duration_ms, analyzed_at = now()
                    """).run()
                try await sql.raw("""
                    DELETE FROM nas_faces WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256)
                    """).run()
                for entry in sealedFaces {
                    try await sql.raw("""
                        INSERT INTO nas_faces
                            (user_id, sha256, ordinal, frame, frame_ms, box, landmarks,
                             score, size_px, sharpness, embedding)
                        VALUES (\(bind: userID), \(bind: sha256), \(bind: entry.ordinal),
                                \(bind: entry.face.frame), \(bind: entry.face.frameMS),
                                \(bind: Self.realArray(entry.face.box))::real[],
                                \(bind: Self.realArray(entry.face.landmarks))::real[],
                                \(bind: entry.face.score), \(bind: entry.face.size),
                                \(bind: entry.face.sharpness), \(bind: entry.sealed))
                        """).run()
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    /// A file the analyzer declined or couldn't finish. Whatever an earlier
    /// analysis stored for it goes, faces included.
    private func record(
        _ item: Candidate, status: String, code: String, health: AnalyzerClient.Health
    ) async throws {
        let userID = item.userID, sha256 = item.sha256
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    INSERT INTO nas_analysis
                        (user_id, sha256, analyzer_version, models, status, error, attempts,
                         frames, scene, face_count, analyzed_at)
                    VALUES (\(bind: userID), \(bind: sha256), \(bind: health.analyzer),
                            \(bind: health.modelSummary), \(bind: status), \(bind: code), 1,
                            0, NULL, 0, now())
                    ON CONFLICT (user_id, sha256) DO UPDATE SET
                        attempts = CASE WHEN nas_analysis.status = 'failed'
                                         AND nas_analysis.analyzer_version = EXCLUDED.analyzer_version
                                        THEN nas_analysis.attempts + 1 ELSE 1 END,
                        analyzer_version = EXCLUDED.analyzer_version, models = EXCLUDED.models,
                        status = EXCLUDED.status, error = EXCLUDED.error, frames = 0, scene = NULL,
                        face_count = 0, duration_ms = NULL, analyzed_at = now()
                    """).run()
                try await sql.raw("""
                    DELETE FROM nas_faces WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256)
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        if status == "failed" { window.failed += 1 } else { window.skipped += 1 }
    }

    /// `{0.1,0.2,…}`, for a `real[]` column. Float's description round-trips.
    static func realArray(_ values: [Float]) -> String {
        "{" + values.map { "\($0)" }.joined(separator: ",") + "}"
    }

    // MARK: - What's owed

    private func candidates(version: Int) async throws -> [Candidate] {
        let rows = try await app.sql.raw("""
            SELECT m.user_id AS "userID", a.sha256, a.media_type AS "mediaType",
                   a.blob_ext AS "blobExt", a.storage_path AS "storagePath",
                   u.people_enabled AS "peopleEnabled"
            FROM users u
            JOIN space_members m ON m.user_id = u.id
            JOIN spaces s ON s.id = m.space_id AND s.kind = 'personal'
            JOIN space_assets sa ON sa.space_id = s.id AND sa.deleted_at IS NULL
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN nas_analysis n ON n.user_id = u.id AND n.sha256 = a.sha256
            WHERE u.nas_analysis <> 'off'
              AND u.curation_enabled
              AND u.deleted_at IS NULL
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND (n.sha256 IS NULL
                   OR n.analyzer_version < \(bind: version)
                   OR (n.status = 'failed' AND n.attempts < \(bind: Self.maxAttempts)
                       AND n.analyzed_at < now() - interval '6 hours'))
            -- Never seen before first, then what arrived in the last two days,
            -- then the library from newest to oldest: what people are looking
            -- at this week is ready first.
            ORDER BY (n.sha256 IS NULL) DESC,
                     (a.created_at > now() - interval '2 days') DESC,
                     COALESCE(a.local_captured_at, a.created_at AT TIME ZONE 'UTC') DESC NULLS LAST,
                     a.sha256
            LIMIT \(bind: Self.batchSize)
            """).all(decoding: Candidate.self)
        var seen = Set<String>()
        return rows.filter { seen.insert("\($0.userID)|\($0.sha256)").inserted }
    }

    private func waiting(version: Int) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await app.sql.raw("""
            SELECT count(DISTINCT (m.user_id, a.sha256))::int AS count
            FROM users u
            JOIN space_members m ON m.user_id = u.id
            JOIN spaces s ON s.id = m.space_id AND s.kind = 'personal'
            JOIN space_assets sa ON sa.space_id = s.id AND sa.deleted_at IS NULL
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN nas_analysis n ON n.user_id = u.id AND n.sha256 = a.sha256
            WHERE u.nas_analysis <> 'off'
              AND u.curation_enabled
              AND u.deleted_at IS NULL
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND (n.sha256 IS NULL
                   OR n.analyzer_version < \(bind: version)
                   OR (n.status = 'failed' AND n.attempts < \(bind: Self.maxAttempts)))
            """).first(decoding: Count.self)?.count ?? 0
    }

    /// A line every ten minutes while there's work, and one when it runs out.
    private func report(version: Int, force: Bool) async {
        let total = window.analyzed + window.skipped + window.failed
        let elapsed = ContinuousClock.now - window.started
        guard total > 0, force || elapsed >= .seconds(600) else { return }
        let left = (try? await waiting(version: version)).map(String.init) ?? "unknown"
        let minutes = max(1, Int(elapsed.components.seconds / 60))
        app.logger.info("analysis: \(window.analyzed) analyzed, \(window.skipped) skipped, \(window.failed) failed in \(minutes) min; \(left) waiting")
        window = Window()
    }

    // What was analyzed for a file no longer in its person's library goes in
    // `RetentionWorker`'s hourly pass, faces and their names included. It
    // used to go from here, which meant only while the analyzer answered.
}

struct AnalysisWorkerKey: StorageKey {
    typealias Value = AnalysisWorker
}

/// Stops the worker as the server shuts down, before the database pool goes:
/// unlike the hourly sweepers, it reaches for the database every few seconds.
struct AnalysisWorkerLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.storage[AnalysisWorkerKey.self]?.stop()
        await application.storage[NASScorerKey.self]?.stop()
        await application.storage[PeopleClustererKey.self]?.stop()
    }
}
