import FrameStationAPI
import Foundation
import NIOCore
import SQLKit
import Vapor

/// Drains `derivation_jobs`.
///
/// Thumbnailing 100k assets has to survive restarts and resume where it
/// stopped, which is why this is a database queue rather than an in-memory
/// pipeline. Jobs are claimed with `FOR UPDATE SKIP LOCKED` so several workers
/// can run concurrently without contending for the same row.
actor DerivationWorker {
    private let app: Application
    private let concurrency: Int
    private var running = false

    /// Idle backoff. Uploads are bursty — long quiet stretches, then a device
    /// dumps a thousand items — so polling slowly when empty costs nothing.
    private let idleDelay: Duration = .seconds(5)

    init(app: Application, concurrency: Int) {
        self.app = app
        self.concurrency = max(1, concurrency)
    }

    struct Job: Decodable {
        let id: UUID
        let assetID: UUID
        let kind: String
    }

    struct AssetRow: Decodable {
        let id: UUID
        let sha256: String
        /// Canonical file path, or nil for rows still in the blob store.
        let storagePath: String?
        let mediaType: String
        let blobExt: String
    }

    /// Where an asset sits, so a finished derivation can be announced.
    ///
    /// Both halves matter. `/changes` is scoped per space, and it filters on
    /// `entity = 'space_asset'` and hydrates by the *placement* id — so
    /// announcing the asset's own id under `entity = 'asset'` is silently
    /// dropped on the floor.
    struct SpacePlacement: Decodable {
        let id: UUID
        let spaceID: UUID
    }

    func start() {
        guard !running else { return }
        running = true

        let missing = Derivatives.missingTools()
        if !missing.isEmpty {
            app.logger.warning(
                "media tools missing (\(missing.joined(separator: ", "))) — derivation disabled"
            )
            return
        }

        app.logger.info("derivation worker starting (\(concurrency) lanes)")

        // Nothing can genuinely be running at startup, so anything left in that
        // state is from a process that died mid-job. Requeue immediately rather
        // than waiting out the 15-minute stale window.
        Task { [app] in
            do {
                try await app.sql.raw("""
                    UPDATE derivation_jobs
                    SET state = 'pending', attempts = GREATEST(attempts - 1, 0)
                    WHERE state = 'running'
                    """).run()
            } catch {
                app.logger.error("could not requeue abandoned jobs: \(error)")
            }
        }

        for lane in 0..<concurrency {
            Task.detached(priority: .utility) { [app] in
                await Self.runLane(lane: lane, app: app, idleDelay: self.idleDelay)
            }
        }
    }

    func stop() { running = false }

    // MARK: - Lane

    private static func runLane(lane: Int, app: Application, idleDelay: Duration) async {
        while !app.didShutdown {
            do {
                let claimed = try await claim(app: app)
                guard let job = claimed else {
                    try await Task.sleep(for: idleDelay)
                    continue
                }
                await process(job: job, app: app)
            } catch is CancellationError {
                return
            } catch {
                app.logger.error("derivation lane \(lane) error: \(error)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Atomically takes the oldest claimable job.
    ///
    /// Deliberately NOT on a pinned connection. This is a single
    /// `UPDATE … RETURNING` — atomic on its own, with no BEGIN/COMMIT to
    /// bracket — so pinning bought nothing and leaked a pooled connection per
    /// call. Four jobs would succeed and the fifth would block forever on its
    /// first query, with no error and no subprocess running.
    private static func claim(app: Application) async throws -> Job? {
        try await app.sql.raw("""
                UPDATE derivation_jobs
                SET state = 'running', started_at = now(), attempts = attempts + 1
                WHERE id = (
                    SELECT id FROM derivation_jobs
                    WHERE state = 'pending'
                       OR (state = 'failed' AND attempts < 3)
                       -- Reclaim jobs abandoned mid-flight. Without this a
                       -- worker that dies while processing leaves the row in
                       -- 'running' forever and nothing ever picks it up again.
                       -- 15 minutes is comfortably longer than the longest
                       -- subprocess timeout.
                       OR (state = 'running'
                           AND started_at < now() - interval '15 minutes'
                           AND attempts < 3)
                    ORDER BY created_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
            RETURNING id, asset_id AS "assetID", kind
            """).first(decoding: Job.self)
    }

    private static func process(job: Job, app: Application) async {
        do {
            guard let asset = try await app.sql.raw("""
                SELECT id, sha256, media_type AS "mediaType", blob_ext AS "blobExt",
                       storage_path AS "storagePath"
                FROM assets WHERE id = \(bind: job.assetID)
                """).first(decoding: AssetRow.self) else {
                try await finish(job: job, app: app, error: "asset no longer exists")
                return
            }

            let mediaType = MediaType(rawValue: asset.mediaType) ?? .photo
            // Prefer the library copy; fall back to the blob for rows that
            // predate the library layout.
            let blob: URL
            if let path = asset.storagePath, FileManager.default.fileExists(atPath: path) {
                blob = URL(fileURLWithPath: path)
            } else {
                blob = app.blobStore.blobPath(
                sha256: asset.sha256,
                fileExtension: asset.blobExt
                )
            }
            guard FileManager.default.fileExists(atPath: blob.path) else {
                try await finish(job: job, app: app, error: "blob missing at \(blob.path)")
                return
            }

            app.logger.info("derivation start \(job.kind) \(asset.sha256.prefix(8)) (\(asset.mediaType))")

            switch job.kind {
            case "metadata":
                let metadata = try await MediaProbe.probe(url: blob, mediaType: mediaType)
                try await applyMetadata(
                    metadata, assetID: asset.id, on: app.sql, geocoder: app.geocoder
                )

            case "thumbnails":
                let output = try await Derivatives.generate(
                    blob: blob,
                    sha256: asset.sha256,
                    mediaType: mediaType,
                    store: app.blobStore,
                    logger: app.logger
                )
                let assetID = asset.id
                let thumbHash = output.thumbHash.map { ByteBuffer(bytes: $0) }
                let width = output.width
                let height = output.height

                // Announced, not just recorded.
                //
                // This is the moment a grey tile becomes a picture: before it,
                // the asset has no thumbnail and no ThumbHash, so the grid draws
                // a blank rectangle and `PhotoCell` won't even request an image
                // because `isDerived` is false. Setting `derived_at` silently
                // left every client holding a cached item that still said
                // false — and since nothing changes the item's id, the cell
                // never reloads either. The tile stayed grey until the app was
                // relaunched, which hit hardest the one person guaranteed to be
                // looking: whoever just uploaded.
                //
                // Delta sync already exists to carry exactly this. It was simply
                // never told. One row per space the asset belongs to, because
                // `/changes` is scoped per space.
                try await app.withPinnedConnection { sql in
                    try await sql.raw("BEGIN").run()
                    do {
                        try await sql.raw("""
                            UPDATE assets
                            SET thumbhash  = \(bind: thumbHash),
                                width      = COALESCE(width, \(bind: width)),
                                height     = COALESCE(height, \(bind: height)),
                                derived_at = now()
                            WHERE id = \(bind: assetID)
                            """).run()

                        let placements = try await sql.raw("""
                            SELECT id, space_id AS "spaceID" FROM space_assets
                            WHERE asset_id = \(bind: assetID) AND deleted_at IS NULL
                            """).all(decoding: SpacePlacement.self)

                        for placement in placements {
                            _ = try await ChangeLog.append(
                                spaceID: placement.spaceID, entity: "space_asset",
                                entityID: placement.id, op: "update", on: sql
                            )
                        }
                        try await sql.raw("COMMIT").run()
                    } catch {
                        try? await sql.raw("ROLLBACK").run()
                        throw error
                    }
                }

            default:
                try await finish(job: job, app: app, error: "unknown job kind \(job.kind)")
                return
            }

            app.logger.info("derivation done \(job.kind) \(asset.sha256.prefix(8))")
            try await finish(job: job, app: app, error: nil)
        } catch {
            app.logger.error("derivation \(job.kind) failed for \(job.assetID): \(error)")
            try? await finish(job: job, app: app, error: String(describing: error))
        }
    }

    private static func finish(job: Job, app: Application, error: String?) async throws {
        try await app.sql.raw("""
            UPDATE derivation_jobs
            SET state = \(bind: error == nil ? "done" : "failed"),
                last_error = \(bind: error),
                finished_at = now()
            WHERE id = \(bind: job.id)
            """).run()
    }

    // MARK: - Shared helpers

    /// Client-supplied values win where the device is authoritative — capture
    /// time and dimensions come from `PHAsset`, which is reliable where EXIF is
    /// often absent or timezone-naive. Everything else is server-only, so the
    /// probe fills it in without clobbering anything on a re-run.
    static func applyMetadata(
        _ metadata: MediaProbe.Metadata,
        assetID: UUID,
        on sql: any SQLDatabase,
        geocoder: Geocoder? = nil
    ) async throws {
        var placeName: String?
        if let latitude = metadata.latitude, let longitude = metadata.longitude {
            placeName = geocoder?.label(latitude: latitude, longitude: longitude)
        }
        try await sql.raw("""
            UPDATE assets SET
                width           = COALESCE(width, \(bind: metadata.width)),
                height          = COALESCE(height, \(bind: metadata.height)),
                duration_ms     = COALESCE(duration_ms, \(bind: metadata.durationMs)),
                captured_at     = COALESCE(captured_at, \(bind: metadata.capturedAt)),
                captured_tz_off = COALESCE(
                    captured_tz_off, \(bind: metadata.capturedTZOffset), tz_off_fallback
                ),
                lat             = COALESCE(lat, \(bind: metadata.latitude)),
                lon             = COALESCE(lon, \(bind: metadata.longitude)),
                camera_make     = COALESCE(\(bind: metadata.cameraMake), camera_make),
                camera_model    = COALESCE(\(bind: metadata.cameraModel), camera_model),
                lens            = COALESCE(\(bind: metadata.lens), lens),
                iso             = COALESCE(\(bind: metadata.iso), iso),
                aperture        = COALESCE(\(bind: metadata.aperture), aperture),
                shutter         = COALESCE(\(bind: metadata.shutter), shutter),
                focal_len       = COALESCE(\(bind: metadata.focalLength), focal_len),
                exposure_bias   = COALESCE(\(bind: metadata.exposureBias), exposure_bias),
                dynamic_range   = COALESCE(\(bind: metadata.dynamicRange), dynamic_range),
                orientation     = COALESCE(\(bind: metadata.orientation), orientation),
                place_name      = COALESCE(\(bind: placeName), place_name)
            WHERE id = \(bind: assetID)
            """).run()

        // Kept in step with captured_at in a second statement rather than a
        // generated column: `timestamptz AT TIME ZONE text` is STABLE, not
        // IMMUTABLE, so Postgres won't accept it as GENERATED. See 0004.
        try await sql.raw("""
            UPDATE assets
            SET local_captured_at =
                (captured_at + COALESCE(captured_tz_off, 0) * interval '1 second') AT TIME ZONE 'UTC'
            WHERE id = \(bind: assetID) AND captured_at IS NOT NULL
            """).run()
    }

    static func enqueue(assetID: UUID, kind: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO derivation_jobs (asset_id, kind) VALUES (\(bind: assetID), \(bind: kind))
            ON CONFLICT (asset_id, kind)
            DO UPDATE SET state = 'pending', attempts = 0, last_error = NULL
            """).run()
    }
}

struct DerivationWorkerKey: StorageKey {
    typealias Value = DerivationWorker
}
