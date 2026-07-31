import Foundation
import FrameStationAPI
import Vapor

enum Build {
    /// Bumped by hand per milestone. Surfaced by /health so you can tell at a
    /// glance which image the NAS is actually running.
    static let version = "1.1.0-M9"
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

    try app.register(collection: HealthController())
    try app.grouped("v1").register(collection: AuthController())
    try app.grouped("v1").register(collection: DSMAuthController())
    try app.grouped("v1").register(collection: SessionController())
    try app.grouped("v1").register(collection: UploadController())
    try app.grouped("v1").register(collection: AssetController())
    try app.grouped("v1").register(collection: TimelineController())
    try app.grouped("v1").register(collection: FavoriteController())
    try app.grouped("v1").register(collection: SpaceController())
    try app.grouped("v1").register(collection: PushController())
    try app.grouped("v1").register(collection: ActivityController())
    try app.grouped("v1").register(collection: AlbumController())

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

        let apnsConfiguration = try APNsClient.Configuration.fromEnvironment()
        if apnsConfiguration == nil {
            app.logger.notice(
                "push disabled — set FRAMESTATION_APNS_KEY_PATH, _KEY_ID, _TEAM_ID, _TOPIC"
            )
        }
        let apns = APNsClient(
            configuration: apnsConfiguration, client: app.client, logger: app.logger
        )
        let sweeper = ActivitySweeper(app: app, apns: apns)
        app.storage[ActivitySweeperKey.self] = sweeper
        await sweeper.start()
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
