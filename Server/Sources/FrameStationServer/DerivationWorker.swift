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

    /// Set once the lanes are running. See `deriveNow(assetID:)`.
    private var lanesStarted = false

    /// Whether a lane is building a playback rendition.
    ///
    /// One at a time. A 4K transcode holds its lane for minutes, and when two
    /// ran at once after a restart they had half the lanes and the processor
    /// besides, while photos from an import filled in behind them at about
    /// three a minute. Only the lane holding this may claim one; see `next()`.
    private var transcoding = false

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

    /// The size on record, before a probe's is reconciled with it.
    private struct RecordedSize: Decodable {
        let width: Int?
        let height: Int?
    }

    func start() async {
        guard !running else { return }
        running = true

        let missing = Derivatives.missingTools()
        if !missing.isEmpty {
            app.logger.warning(
                "media tools missing (\(missing.joined(separator: ", "))) — derivation disabled"
            )
            return
        }

        let transcodes = Derivatives.transcodeProcessors.map { "cores \($0)" }
            ?? "\(Derivatives.playbackThreads) threads"
        app.logger.info(
            "derivation worker starting (\(concurrency) lanes, one transcode at a time on \(transcodes))"
        )

        // Nothing can genuinely be running at startup, so anything left in that
        // state is from a process that died mid-job. Requeue immediately rather
        // than waiting out the 15-minute stale window, and before the lanes
        // start rather than beside them, so their first claims can see it.
        do {
            try await app.sql.raw("""
                UPDATE derivation_jobs
                SET state = 'pending', attempts = GREATEST(attempts - 1, 0)
                WHERE state = 'running'
                """).run()
        } catch {
            app.logger.error("could not requeue abandoned jobs: \(error)")
        }

        for lane in 0..<concurrency {
            Task.detached(priority: .utility) { [app] in
                await Self.runLane(lane: lane, worker: self, app: app, idleDelay: self.idleDelay)
            }
        }
        lanesStarted = true
    }

    func stop() { running = false }

    /// Makes an asset's thumbnails now, for someone who opened it before the
    /// queue got to it. Does nothing if it has them already, or a lane is
    /// making them.
    ///
    /// Run here, at full priority, rather than moved up the queue: the lanes
    /// run behind everything else for the processor and can all be busy, and
    /// the person is looking at the photo now. It takes the job with the same
    /// sort of atomic claim a lane uses, so no lane can start it as well. Not
    /// before the lanes have started, though, because until then the boot's
    /// requeue would put a claimed job back in line and a lane would make it
    /// a second time.
    func deriveNow(assetID: UUID) async {
        guard lanesStarted else { return }
        do {
            guard let job = try await app.sql.raw("""
                INSERT INTO derivation_jobs (asset_id, kind, state, attempts, started_at)
                SELECT id, 'thumbnails', 'running', 1, now()
                FROM assets WHERE id = \(bind: assetID) AND derived_at IS NULL
                ON CONFLICT (asset_id, kind) DO UPDATE
                SET state = 'running', attempts = 1, started_at = now(), last_error = NULL
                WHERE derivation_jobs.state <> 'running'
                RETURNING id, asset_id AS "assetID", kind
                """).first(decoding: Job.self) else { return }
            app.logger.info("asset \(assetID) opened before its thumbnail was made; making it now")
            await Self.process(job: job, app: app)
        } catch {
            app.logger.error("could not make thumbnails for \(assetID) on open: \(error)")
        }
    }

    // MARK: - Lane

    private static func runLane(
        lane: Int, worker: DerivationWorker, app: Application, idleDelay: Duration
    ) async {
        while !app.didShutdown {
            do {
                guard let job = try await worker.next() else {
                    try await Task.sleep(for: idleDelay)
                    continue
                }
                // Every tool this job starts runs behind the server for the
                // CPU — see `Shell.isBackground`.
                await Shell.$isBackground.withValue(true) {
                    await process(job: job, app: app)
                }
                if job.kind == Derivatives.playbackJobKind {
                    await worker.finishedTranscoding()
                }
            } catch is CancellationError {
                return
            } catch {
                app.logger.error("derivation lane \(lane) error: \(error)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The next job for a lane: a transcode only if no other lane is running one.
    private func next() async throws -> Job? {
        guard !transcoding else {
            return try await Self.claim(app: app, includingTranscodes: false)
        }
        // Taken before the claim, not after it. The actor lets other lanes in
        // while this one waits on the database, and any of them that found the
        // slot free meanwhile would take a transcode too.
        transcoding = true
        do {
            let job = try await Self.claim(app: app, includingTranscodes: true)
            transcoding = job?.kind == Derivatives.playbackJobKind
            return job
        } catch {
            transcoding = false
            throw error
        }
    }

    private func finishedTranscoding() { transcoding = false }

    /// Atomically takes the oldest claimable job.
    ///
    /// Deliberately NOT on a pinned connection. This is a single
    /// `UPDATE … RETURNING` — atomic on its own, with no BEGIN/COMMIT to
    /// bracket — so pinning bought nothing and leaked a pooled connection per
    /// call. Four jobs would succeed and the fifth would block forever on its
    /// first query, with no error and no subprocess running.
    private static func claim(app: Application, includingTranscodes: Bool) async throws -> Job? {
        try await app.sql.raw("""
                UPDATE derivation_jobs
                SET state = 'running', started_at = now(), attempts = attempts + 1
                WHERE id = (
                    SELECT j.id FROM derivation_jobs j
                    JOIN assets a ON a.id = j.asset_id
                    WHERE (j.state = 'pending'
                       OR (j.state = 'failed' AND j.attempts < 3)
                       -- Reclaim jobs abandoned mid-flight. Without this a
                       -- worker that dies while processing leaves the row in
                       -- 'running' forever and nothing ever picks it up again.
                       -- 15 minutes is comfortably longer than any subprocess
                       -- timeout but a transcode's, and a transcode can't be
                       -- taken from under itself: only the lane allowed to
                       -- transcode may claim one, and it is busy with that one.
                       OR (j.state = 'running'
                           AND j.started_at < now() - interval '15 minutes'
                           AND j.attempts < 3))
                      -- One transcode at a time; see `transcoding`.
                      AND (\(bind: includingTranscodes)
                           OR j.kind <> \(bind: Derivatives.playbackJobKind))
                    -- Thumbnails first: they are what someone watching the grid
                    -- is waiting on, so a burst of uploads (and the exif-dump
                    -- backfill sharing this queue) fills tiles before it spends
                    -- lanes on the deep metadata behind them.
                    --
                    -- And among those, a photo with no thumbnail yet before one
                    -- being rebuilt. A rebuild re-pends a job that keeps its
                    -- old created_at, so oldest-first alone put a library-wide
                    -- rebuild (every video's poster, say) ahead of whatever
                    -- somebody uploads while it runs, leaving their new photos
                    -- gray until the whole rebuild had finished.
                    ORDER BY (j.kind = 'thumbnails') DESC,
                             (a.derived_at IS NULL) DESC,
                             j.created_at
                    FOR UPDATE OF j SKIP LOCKED
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
                // This is the moment a gray tile becomes a picture: before it,
                // the asset has no thumbnail and no ThumbHash, so the grid draws
                // a blank rectangle and `PhotoCell` won't even request an image
                // because `isDerived` is false. Setting `derived_at` silently
                // left every client holding a cached item that still said
                // false — and since nothing changes the item's id, the cell
                // never reloads either. The tile stayed gray until the app was
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
                            SET thumbhash     = \(bind: thumbHash),
                                width         = COALESCE(width, \(bind: width)),
                                height        = COALESCE(height, \(bind: height)),
                                derived_at    = now(),
                                thumb_version = \(bind: Derivatives.thumbnailVersion(for: mediaType))
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

            case Derivatives.playbackJobKind:
                // Only video has one, and only video above the bitrate
                // threshold — see `makePlaybackRendition`.
                guard mediaType == .video else { break }

                // Fetched here rather than widened into the shared `AssetRow`:
                // every other job kind would carry two columns it never reads.
                struct Shape: Decodable {
                    let byteSize: Int?
                    let durationMS: Int?
                    let width: Int?
                    let height: Int?
                }
                let shape = try await app.sql.raw("""
                    SELECT byte_size AS "byteSize", duration_ms AS "durationMS",
                           width, height
                    FROM assets WHERE id = \(bind: asset.id)
                    """).first(decoding: Shape.self)

                // Bits per second from what is already on the row, so no new
                // column is needed. Unknown duration means unknown bitrate,
                // which `makePlaybackRendition` treats as "build it" — better a
                // wasted transcode than a clip that stutters on cellular.
                var bitrate: Int?
                if let bytes = shape?.byteSize, let ms = shape?.durationMS, ms > 0 {
                    bitrate = Int(Double(bytes) * 8.0 / (Double(ms) / 1000.0))
                }

                // Nil when the probe never recorded dimensions, which the
                // rendition treats as "scale it" — the clip is over the bitrate
                // threshold, so it is very unlikely to be small.
                let longEdge = [shape?.width, shape?.height].compactMap(\.self).max()

                _ = try await Derivatives.makePlaybackRendition(
                    blob: blob,
                    sha256: asset.sha256,
                    sourceBitrate: bitrate,
                    sourceLongEdge: longEdge,
                    sourceDurationMS: shape?.durationMS,
                    store: app.blobStore,
                    logger: app.logger
                )

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
    /// time comes from `PHAsset`, which is reliable where EXIF is often absent
    /// or timezone-naive. Everything else is server-only, so the probe fills it
    /// in without clobbering anything on a re-run.
    ///
    /// Dimensions are both. `PHAsset`'s numbers are kept, but turned to lie
    /// the way the file's pixels do, because the orientation recorded beside
    /// them is the file's — see `ExifOrientation.fileOrientedSize`. Kept as
    /// the phone said them, every portrait iPhone photo reported landscape.
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

        // The full dump for the `exif` jsonb column, as JSON text bound and
        // cast below. Three states, from `Metadata.raw`:
        //   • not attempted (nil)     → nil here, and the COALESCE leaves exif
        //                                as it was, so the asset stays eligible
        //                                for a later backfill pass.
        //   • attempted, empty ([])   → "[]", written so the asset is no longer
        //                                null and stops being re-probed.
        //   • a real dump             → the encoded JSON, overwriting whatever
        //                                was there (it's derived from the bytes).
        let exifValue: String?
        switch metadata.raw {
        case .some(let groups) where !groups.isEmpty:
            exifValue = (try? JSONEncoder().encode(groups)).map { String(decoding: $0, as: UTF8.self) }
        case .some:
            exifValue = "[]"
        case .none:
            exifValue = nil
        }

        let recorded = try await sql.raw("""
            SELECT width, height FROM assets WHERE id = \(bind: assetID)
            """).first(decoding: RecordedSize.self)
        let size = ExifOrientation.fileOrientedSize(
            recorded: (recorded?.width, recorded?.height),
            file: (metadata.width, metadata.height)
        )

        try await sql.raw("""
            UPDATE assets SET
                width           = \(bind: size.width),
                height          = \(bind: size.height),
                duration_ms     = COALESCE(duration_ms, \(bind: metadata.durationMs)),
                -- Client date first, then EXIF, then the file's own creation
                -- date the client sent as a fallback (0021): a screenshot has
                -- no EXIF date, so this is the only capture time there is.
                captured_at     = COALESCE(captured_at, \(bind: metadata.capturedAt), captured_at_fallback),
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
                place_name      = COALESCE(\(bind: placeName), place_name),
                exif            = COALESCE(\(bind: exifValue)::jsonb, exif)
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
