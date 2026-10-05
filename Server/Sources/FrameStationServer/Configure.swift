import Foundation
import FrameStationAPI
import Vapor

enum Build {
    /// Bumped by hand per milestone. Surfaced by /health, but a label rather
    /// than an identity — see `revision` for which build is actually running.
    static let version = "1.1.0-M9"

    /// The git commit this image was built from, stamped into the image by CI
    /// (`FRAMESTATION_REVISION`, see Server/Dockerfile). Nil for a local build.
    ///
    /// The answer to "is the NAS running what I pushed?" in one request, where
    /// it used to take `docker inspect` over SSH with sudo.
    static let revision: String? = {
        guard let value = ProcessInfo.processInfo.environment["FRAMESTATION_REVISION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "unknown"
        else { return nil }
        return value
    }()
}

func configure(_ app: Application) async throws {
    guard let databaseURL = Environment.get("FRAMESTATION_DATABASE_URL") else {
        app.logger.critical("FRAMESTATION_DATABASE_URL is not set")
        throw ConfigurationError.missingDatabaseURL
    }

    try app.configurePostgres(url: databaseURL)

    // Blob root isn't written to until M1, but failing here beats discovering a
    // missing bind mount halfway through an 800 GB import.
    let blobRoot = Environment.get("FRAMESTATION_BLOB_ROOT") ?? "/data"
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: blobRoot, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        app.logger.critical("FRAMESTATION_BLOB_ROOT '\(blobRoot)' does not exist or is not a directory")
        throw ConfigurationError.blobRootUnavailable(blobRoot)
    }
    app.blobStore = BlobStore(root: blobRoot)
    app.logger.info("blob root: \(blobRoot)")

    // Pinned explicitly rather than left to Vapor's defaults, so the server and
    // the Swift clients cannot drift on date representation. See
    // FrameStationCoding for why that drift is otherwise silent.
    ContentConfiguration.global.use(encoder: FrameStationCoding.encoder, for: .json)
    ContentConfiguration.global.use(decoder: FrameStationCoding.decoder, for: .json)

    // Sized for M1's chunked uploads; a 16 MB chunk plus multipart overhead.
    app.routes.defaultMaxBodySize = "24mb"

    let applied = try await app.withPinnedConnection { sql in
        try await Migrator(logger: app.logger).migrate(on: sql)
    }
    app.logger.info("schema at \(applied) migration(s)")

    // Optional: absent dataset just means place_name stays null, which the
    // clients already handle by showing raw coordinates.
    let geonames = Environment.get("FRAMESTATION_GEONAMES_DIR") ?? "/opt/geonames"
    let geocoder = Geocoder(logger: app.logger)
    if geocoder.load(directory: geonames) { app.geocoder = geocoder }

    app.asyncCommands.use(InviteCommand(), as: "invite")
    app.asyncCommands.use(SpacesCommand(), as: "spaces")
    app.asyncCommands.use(ImportCommand(), as: "import")
    app.asyncCommands.use(GeocodeCommand(), as: "geocode")
    app.asyncCommands.use(RebuildCommand(), as: "rebuild")
    app.asyncCommands.use(RepairDimensionsCommand(), as: "repair-dimensions")
    app.asyncCommands.use(RetireLegacyBrowseCommand(), as: "retire-legacy-browse")

    try app.register(collection: HealthController())
    try app.grouped("v1").register(collection: AuthController())
    try app.grouped("v1").register(collection: DSMAuthController())
    try app.grouped("v1").register(collection: SessionController())
    try app.grouped("v1").register(collection: UploadController())
    try app.grouped("v1").register(collection: AssetController())
    try app.grouped("v1").register(collection: TimelineController())
    try app.grouped("v1").register(collection: SearchController())
    try app.grouped("v1").register(collection: FavoriteController())
    try app.grouped("v1").register(collection: MetadataController())
    try app.grouped("v1").register(collection: MediaEditController())
    try app.grouped("v1").register(collection: SpaceController())
    try app.grouped("v1").register(collection: PushController())
    try app.grouped("v1").register(collection: ActivityController())
    try app.grouped("v1").register(collection: AlbumController())
    try app.grouped("v1").register(collection: CollectionsController())
    try app.grouped("v1").register(collection: CurationController())

    // Only the long-running server drains the queue.
    //
    // configure() runs before command dispatch, so without this check every
    // CLI invocation — `import`, `invite`, `spaces` — also spins up worker
    // lanes. Those processes claim jobs and then exit seconds later, leaving
    // the rows stranded in 'running' with no error and no process behind them.
    // A single `docker compose exec server ./FrameStationServer invite` is
    // enough to strand a job on a live system.
    if isServeCommand(app) {
        // One lane per core, capped: the J4125 has four, and thumbnailing is
        // CPU-bound, so oversubscribing just adds context switching.
        let lanes = Environment.get("FRAMESTATION_DERIVATION_LANES").flatMap(Int.init)
            ?? min(4, ProcessInfo.processInfo.activeProcessorCount)
        let worker = DerivationWorker(app: app, concurrency: lanes)
        app.storage[DerivationWorkerKey.self] = worker
        await worker.start()

        // APNs speaks HTTP/2 only; without this the client offers 1.1 and the
        // connection is refused before any push is attempted.
        app.http.client.configuration.httpVersion = .automatic

        // A key that can't be read turns push off rather than the server:
        // notifications are the one thing here that can go missing without
        // anybody's photographs being at risk.
        let secrets = (blobRoot as NSString).appendingPathComponent("secrets")
        let apnsConfiguration: APNsClient.Configuration?
        do {
            apnsConfiguration = try APNsClient.Configuration.fromEnvironment(
                secretsDirectory: secrets
            )
        } catch {
            app.logger.error("push disabled — the APNs key could not be read: \(error)")
            apnsConfiguration = nil
        }
        if let apnsConfiguration {
            app.logger.info(
                "push enabled — key \(apnsConfiguration.keyID), topic \(apnsConfiguration.topic)"
            )
        } else {
            app.logger.notice(
                "push disabled — put AuthKey_<KEY ID>.p8 in \(secrets) to turn it on"
            )
        }
        let apns = APNsClient(
            configuration: apnsConfiguration, client: app.client, logger: app.logger
        )
        let browse = BrowseTreeWorker(
            app: app, configuration: BrowseTree.Configuration.fromEnvironment()
        )
        app.storage[BrowseTreeWorkerKey.self] = browse
        await browse.start()

        let sweeper = ActivitySweeper(app: app, apns: apns)
        app.storage[ActivitySweeperKey.self] = sweeper
        await sweeper.start()

        // The other half of what push is for: telling people what arrived, and
        // getting a phone that stalled overnight moving again.
        let nudger = BackupNudger(app: app, apns: apns)
        app.storage[BackupNudgerKey.self] = nudger
        await nudger.start()

        let retention = RetentionWorker(app: app)
        app.storage[RetentionWorkerKey.self] = retention
        await retention.start()

        // Ready before the first upload rather than started by it. See
        // `ExifToolDaemon.warm`.
        Task { await ExifToolDaemon.shared.warm() }

        // Photos analyzed under older curation rules get the current ones,
        // with no device involved. See `CurationVocabulary.retag`.
        Task { await CurationVocabulary.retag(on: app) }

        // Fill dates and the screenshot kind into already-stored assets from
        // their filenames, so the library that predates this reading gains the
        // metadata without a re-upload. One pass, in the background, off the
        // boot path.
        Task { await MetadataBackfill.run(on: app) }
        // And re-probe already-stored files for the full technical dump the
        // Information panel now shows — same "no re-upload" idea, but the work
        // goes on the derivation queue rather than running inline.
        Task { await MetadataBackfill.enqueueMissingExif(on: app) }
        // Heal any live asset that reached the grid without a thumbnail — the
        // dedup/purge bug left a handful gray with no job. Runs after the exif
        // enqueue, but thumbnails outrank metadata in the worker, so these fill
        // first regardless of order.
        Task { await MetadataBackfill.enqueueMissingThumbnails(on: app) }
        // Videos uploaded before the cellular rendition existed. Last, and
        // bounded: it is the only job here that can occupy a worker for minutes
        // at a time, and nothing on screen is waiting for it.
        Task { await MetadataBackfill.enqueueMissingPlaybackRenditions(on: app) }
        // And rebuild any whose file has since vanished — including one the
        // generator itself discarded for being unplayable.
        Task { await MetadataBackfill.requeueVanishedPlaybackRenditions(on: app) }
        // Take apart the old hardlink tree under the blob root, which kept the
        // bytes of permanently deleted photos on disk. Once it is gone this is
        // a single failed `stat` per boot.
        Task { await LegacyBrowseTree.retireInBackground(app: app) }
    }

    app.logger.info("framestation \(Build.version) configured")
}

enum ConfigurationError: Error, CustomStringConvertible {
    case missingDatabaseURL
    case blobRootUnavailable(String)

    var description: String {
        switch self {
        case .missingDatabaseURL:
            return "FRAMESTATION_DATABASE_URL is required (postgres://user:pass@host:5432/db)."
        case .blobRootUnavailable(let path):
            return "FRAMESTATION_BLOB_ROOT '\(path)' is missing or not a directory."
        }
    }
}

/// True when this process is running the HTTP server rather than a one-shot
/// CLI command. `serve` is also Vapor's default when no command is given.
func isServeCommand(_ app: Application) -> Bool {
    let arguments = app.environment.arguments
    guard arguments.count > 1 else { return true }
    let command = arguments[1]
    if command.hasPrefix("-") { return true }
    return command == "serve"
}
