import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension SubmitObservationsRequest: @retroactive Content {}
extension SubmitObservationsResponse: @retroactive Content {}
extension SubmitWrittenNumbersRequest: @retroactive Content {}
extension PendingAnalysisResponse: @retroactive Content {}
extension CurationSettings: @retroactive Content {}
extension UpdateCurationSettingsRequest: @retroactive Content {}
extension CurationStatus: @retroactive Content {}
extension AssetObservationDetail: @retroactive Content {}
extension NASObservationDetail: @retroactive Content {}

/// What a person's devices saw in their photographs, and their say over it.
///
/// The phone does the looking (Vision, on the device) and sends labels, scores
/// and counts here, never pixels. The Albums page turns them into occasions in
/// `CollectionsController`. See ARCHITECTURE.md, "Curated albums".
///
/// Personal libraries only, for now: every request about analysis is scoped to
/// the caller's own library, and every row it touches is the caller's own.
/// Nothing here logs what a photo showed. Counts only.
struct CurationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("curation", use: status)
        protected.put("curation", "settings", use: updateSettings)
        protected.delete("curation", "data", use: deleteData)
        protected.get("spaces", ":spaceID", "curation", "pending", use: pending)
        protected.post("spaces", ":spaceID", "curation", "observations", use: submit)
        protected.get("spaces", ":spaceID", "curation", "written", "pending", use: pendingWriting)
        protected.post("spaces", ":spaceID", "curation", "written", use: submitWriting)
        protected.get("spaces", ":spaceID", "assets", ":assetID", "observation", use: observation)
        protected.get("spaces", ":spaceID", "assets", ":assetID", "nas-observation", use: nasObservation)
    }

    /// More than this in one request is a client bug, not a big library.
    static let maxBatch = 500
    /// Vision keeps a confidence for every one of its 1,303 labels. A device
    /// sends only the strongest, and the server keeps no more than this.
    static let maxLabels = 40

    // MARK: - Settings and status

    struct Context {
        let enabled: Bool
        let holidays: Bool
        /// Whether the space is the caller's own personal library, the only
        /// kind curated for now.
        let isPersonal: Bool
        /// `users.nas_analysis`: off, shadow or on.
        var nas: String = "off"
        /// Whether they're previewing the page built from the NAS's analysis.
        var nasPreview = false
        /// `users.people_enabled`: People, on or off.
        var people = true

        /// Whether this space has People: the caller's own library, analyzed
        /// by the NAS, with People on.
        var showsPeople: Bool { isPersonal && nas != "off" && people }

        /// Where the page's tags and search's words come from.
        var source: ObservationSource {
            ObservationSource(nas: nas, preview: nasPreview)
        }

        /// Whether the page may save and refine kept albums. Not while
        /// previewing; see `CuratedAlbums.persists`.
        var persistsAlbums: Bool {
            !(nasPreview && nas == "shadow")
        }
    }

    /// The caller's settings, and whether this space is theirs to curate.
    static func context(
        userID: UUID, spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> Context {
        struct Row: Decodable {
            let enabled: Bool
            let holidays: Bool
            let isPersonal: Bool
            let nas: String
            let nasPreview: Bool
            let people: Bool
        }
        let row = try await sql.raw("""
            SELECT u.curation_enabled AS enabled, u.curation_holidays AS holidays,
                   u.nas_analysis AS nas, u.nas_preview AS "nasPreview", u.people_enabled AS people,
                   EXISTS (
                       SELECT 1 FROM spaces s
                       JOIN space_members m ON m.space_id = s.id
                       WHERE s.id = \(bind: spaceID) AND s.kind = 'personal'
                         AND m.user_id = u.id
                   ) AS "isPersonal"
            FROM users u WHERE u.id = \(bind: userID)
            """).first(decoding: Row.self)
        return Context(
            enabled: row?.enabled ?? true,
            holidays: row?.holidays ?? true,
            isPersonal: row?.isPersonal ?? false,
            nas: row?.nas ?? "off",
            nasPreview: row?.nasPreview ?? false,
            people: row?.people ?? true
        )
    }

    /// Whether this person has curation on, and whose observations their
    /// search reads. Nil when curation is off.
    static func observations(userID: UUID, on sql: any SQLDatabase) async throws -> ObservationSource? {
        struct Row: Decodable { let enabled: Bool; let nas: String; let nasPreview: Bool }
        guard let row = try await sql.raw("""
            SELECT curation_enabled AS enabled, nas_analysis AS nas, nas_preview AS "nasPreview"
            FROM users WHERE id = \(bind: userID)
            """).first(decoding: Row.self), row.enabled
        else { return nil }
        return ObservationSource(nas: row.nas, preview: row.nasPreview)
    }

    /// Whether this person has curation on. Everything built from what their
    /// devices recognized, search included, goes quiet when it's off.
    static func isEnabled(userID: UUID, on sql: any SQLDatabase) async throws -> Bool {
        struct Row: Decodable { let enabled: Bool }
        return try await sql.raw("""
            SELECT curation_enabled AS enabled FROM users WHERE id = \(bind: userID)
            """).first(decoding: Row.self)?.enabled ?? false
    }

    private func settings(userID: UUID, on sql: any SQLDatabase) async throws -> CurationSettings {
        struct Row: Decodable { let enabled: Bool; let holidays: Bool }
        guard let row = try await sql.raw("""
            SELECT curation_enabled AS enabled, curation_holidays AS holidays
            FROM users WHERE id = \(bind: userID)
            """).first(decoding: Row.self)
        else { throw Abort(.notFound) }
        return CurationSettings(enabled: row.enabled, holidays: row.holidays)
    }

    /// Settings, and how far the analysis of the caller's own library has got.
    @Sendable
    func status(req: Request) async throws -> CurationStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        struct Counts: Decodable { let analyzed: Int; let total: Int }
        let counts = try await req.sql.raw("""
            SELECT count(o.sha256)::int AS analyzed, count(*)::int AS total
            FROM spaces s
            JOIN space_members m ON m.space_id = s.id AND m.user_id = \(bind: device.userID)
            JOIN space_assets sa ON sa.space_id = s.id AND sa.deleted_at IS NULL
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN media_observations o
                   ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            WHERE s.kind = 'personal'
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
            """).first(decoding: Counts.self)
        return CurationStatus(
            settings: try await settings(userID: device.userID, on: req.sql),
            analyzed: counts?.analyzed ?? 0,
            total: counts?.total ?? 0,
            nas: try await nasStatus(userID: device.userID, total: counts?.total ?? 0, on: req.sql)
        )
    }

    /// For someone the NAS analyzes: how far it's got, and whether they're
    /// previewing the page it would make. Nil for everyone else.
    private func nasStatus(userID: UUID, total: Int, on sql: any SQLDatabase) async throws -> NASAnalysisStatus? {
        struct Row: Decodable { let state: String; let preview: Bool; let people: Bool; let analyzed: Int }
        guard let row = try await sql.raw("""
            SELECT u.nas_analysis AS state, u.nas_preview AS preview, u.people_enabled AS people,
                   (SELECT count(DISTINCT o.sha256)::int
                    FROM spaces s
                    JOIN space_members m ON m.space_id = s.id AND m.user_id = u.id
                    JOIN space_assets sa ON sa.space_id = s.id AND sa.deleted_at IS NULL
                    JOIN assets a ON a.id = sa.asset_id
                    JOIN nas_observations o ON o.user_id = u.id AND o.sha256 = a.sha256
                    WHERE s.kind = 'personal' AND \(unsafeRaw: TimelineController.visible)) AS analyzed
            FROM users u WHERE u.id = \(bind: userID)
            """).first(decoding: Row.self), row.state != "off"
        else { return nil }
        return NASAnalysisStatus(
            state: row.state, analyzed: row.analyzed, total: total, preview: row.preview, people: row.people
        )
    }

    /// Changes only what the request names. On every one of the person's
    /// devices at once, which is why it lives here and not on the phone.
    @Sendable
    func updateSettings(req: Request) async throws -> CurationSettings {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let body = try req.content.decode(UpdateCurationSettingsRequest.self)
        try await req.sql.raw("""
            UPDATE users
            SET curation_enabled = COALESCE(\(bind: body.enabled)::boolean, curation_enabled),
                curation_holidays = COALESCE(\(bind: body.holidays)::boolean, curation_holidays),
                -- Only someone the NAS analyzes can preview what it makes.
                nas_preview = CASE WHEN nas_analysis <> 'off'
                                   THEN COALESCE(\(bind: body.nasPreview)::boolean, nas_preview)
                                   ELSE false END
            WHERE id = \(bind: device.userID)
            """).run()
        if let people = body.people {
            try await Self.setPeople(people, userID: device.userID, app: req.application)
        }
        return try await settings(userID: device.userID, on: req.sql)
    }

    /// People off: the NAS forgets who anyone is. Their people, names and
    /// relationships go, and so does every face template, while each face
    /// keeps its box: how many people a photo has, not who they are. Nothing
    /// new is kept either (`AnalysisWorker`).
    ///
    /// On again: the NAS reads the library again for faces, newest first,
    /// and People fills in as it goes.
    static func setPeople(_ on: Bool, userID: UUID, app: Application) async throws {
        struct Row: Decodable { let people: Bool }
        guard let was = try await app.sql.raw("""
            SELECT people_enabled AS people FROM users WHERE id = \(bind: userID)
            """).first(decoding: Row.self)?.people, was != on
        else { return }
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    UPDATE users SET people_enabled = \(bind: on) WHERE id = \(bind: userID)
                    """).run()
                if on {
                    try await sql.raw("""
                        UPDATE nas_analysis SET analyzer_version = 0 WHERE user_id = \(bind: userID)
                        """).run()
                } else {
                    try await sql.raw("DELETE FROM people WHERE user_id = \(bind: userID)").run()
                    try await sql.raw("""
                        UPDATE nas_faces SET embedding = NULL WHERE user_id = \(bind: userID)
                        """).run()
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        // The clusterer goes by how many faces it last grouped, and a library
        // read again comes back to the same number: told outright instead.
        await app.storage[PeopleClustererKey.self]?.touch(userID)
        app.logger.info("curation: a person turned People \(on ? "on" : "off")")
    }

    /// Forgets everything the caller's devices ever reported. The photographs
    /// themselves, their albums and anything named by hand are untouched.
    @Sendable
    func deleteData(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        try await req.sql.raw("""
            DELETE FROM media_observations WHERE user_id = \(bind: device.userID)
            """).run()
        // And the albums it found: an event is only known from what the
        // devices saw. Trips it named are renamed the next time they're shown.
        try await req.sql.raw("""
            DELETE FROM curated_albums WHERE user_id = \(bind: device.userID) AND is_event
            """).run()
        // And what the NAS's own analyzer saw, faces included (they go with
        // their rows). See NAS-ANALYSIS.md §6.
        try await req.sql.raw("""
            DELETE FROM nas_analysis WHERE user_id = \(bind: device.userID)
            """).run()
        // And the people it found, names included: a name only ever meant
        // the faces it was given to, and those are gone.
        try await req.sql.raw("""
            DELETE FROM people WHERE user_id = \(bind: device.userID)
            """).run()
        req.logger.info("curation: deleted a person's analysis data")
        return .noContent
    }

    // MARK: - Analysis

    /// 404 unless the space is the caller's own personal library.
    private func requirePersonal(_ spaceID: UUID, userID: UUID, on sql: any SQLDatabase) async throws {
        let context = try await Self.context(userID: userID, spaceID: spaceID, on: sql)
        guard context.isPersonal else { throw Abort(.notFound, reason: "No such space.") }
    }

    /// Photos in the caller's library that their devices haven't analyzed at
    /// this version yet, newest first, since recent photographs are the ones
    /// most likely to be looked at.
    ///
    /// Only ones the NAS has made a thumbnail for: the device analyzes the
    /// 512-pixel thumbnail, so it never needs the original. A video is
    /// analyzed by its poster frame. A Live Photo's motion half isn't
    /// analyzed at all; the still speaks for it.
    @Sendable
    func pending(req: Request) async throws -> PendingAnalysisResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await requirePersonal(spaceID, userID: device.userID, on: req.sql)

        let context = try await Self.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.enabled else { return PendingAnalysisResponse(items: [], remaining: 0) }

        let version = max(1, req.query[Int.self, at: "analysisVersion"] ?? 1)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 100, 1), Self.maxBatch)

        struct ItemRow: Decodable { let assetID: UUID; let thumbVersion: Int }
        let items = try await req.sql.raw("""
            SELECT a.id AS "assetID", a.thumb_version AS "thumbVersion"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND NOT EXISTS (
                  SELECT 1 FROM media_observations o
                  WHERE o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
                    AND o.analysis_version >= \(bind: version)
              )
            ORDER BY \(unsafeRaw: TimelineController.localTime) DESC, a.id
            LIMIT \(bind: limit)
            """).all(decoding: ItemRow.self)

        struct CountRow: Decodable { let n: Int }
        let remaining = try await req.sql.raw("""
            SELECT count(*)::int AS n
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND NOT EXISTS (
                  SELECT 1 FROM media_observations o
                  WHERE o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
                    AND o.analysis_version >= \(bind: version)
              )
            """).first(decoding: CountRow.self)?.n ?? 0

        return PendingAnalysisResponse(
            items: items.map { PendingAnalysisItem(assetID: $0.assetID, thumbVersion: $0.thumbVersion) },
            remaining: remaining
        )
    }

    /// Stores what a device saw.
    ///
    /// Each photo is found through the caller's own library, and its hash read
    /// from the asset row, never taken from the request. An id the caller can't
    /// see matches nothing and is simply not counted. That makes this useless
    /// for asking whether a photo exists, the same rule as everywhere else
    /// (ARCHITECTURE.md §4).
    ///
    /// A photo already analyzed at this version keeps its first answer. A
    /// newer version replaces an older one.
    @Sendable
    func submit(req: Request) async throws -> SubmitObservationsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await requirePersonal(spaceID, userID: device.userID, on: req.sql)

        let body = try req.content.decode(SubmitObservationsRequest.self)
        guard body.observations.count <= Self.maxBatch else {
            throw Abort(.payloadTooLarge, reason: "At most \(Self.maxBatch) photos at a time.")
        }
        guard (1...1_000).contains(body.analysisVersion), body.modelVersion.count <= 200 else {
            throw Abort(.badRequest, reason: "Unrecognized analysis version.")
        }

        // Turned off since the device asked what to do: keep nothing.
        let context = try await Self.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.enabled else { return SubmitObservationsResponse(accepted: 0) }

        let hashByAsset = try await Self.hashes(of: body.observations.map(\.assetID), in: spaceID, on: req.sql)

        var accepted = 0
        for observation in body.observations {
            guard let sha256 = hashByAsset[observation.assetID] else { continue }
            let labels = Self.sanitized(observation.labels)
            let labelsJSON = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
            let tags = CurationVocabulary.tags(for: labels, peopleCount: observation.peopleCount)
            let terms = CurationVocabulary.terms(labels: labels, tags: tags)
            let aesthetic = observation.aesthetic.map { min(max($0, -1), 1) }

            let stored = try await req.sql.raw("""
                INSERT INTO media_observations
                    (user_id, sha256, analysis_version, model_version, labels, aesthetic,
                     is_utility, people_count, animal_count, tags, terms, words,
                     vocabulary_version, device_id)
                VALUES (\(bind: device.userID), \(bind: sha256), \(bind: body.analysisVersion),
                        \(bind: body.modelVersion), \(bind: labelsJSON)::jsonb, \(bind: aesthetic),
                        \(bind: observation.isUtility),
                        \(bind: min(max(observation.peopleCount, 0), 999)),
                        \(bind: min(max(observation.animalCount, 0), 999)),
                        \(bind: tags), \(bind: terms),
                        \(bind: CurationVocabulary.words(of: terms)),
                        \(bind: CurationVocabulary.version), \(bind: device.deviceID))
                ON CONFLICT (user_id, sha256) DO UPDATE
                SET analysis_version = EXCLUDED.analysis_version,
                    model_version = EXCLUDED.model_version,
                    labels = EXCLUDED.labels,
                    aesthetic = EXCLUDED.aesthetic,
                    is_utility = EXCLUDED.is_utility,
                    people_count = EXCLUDED.people_count,
                    animal_count = EXCLUDED.animal_count,
                    tags = EXCLUDED.tags,
                    terms = EXCLUDED.terms,
                    words = EXCLUDED.words,
                    vocabulary_version = EXCLUDED.vocabulary_version,
                    device_id = EXCLUDED.device_id,
                    observed_at = now()
                WHERE media_observations.analysis_version < EXCLUDED.analysis_version
                RETURNING sha256
                """).first()
            if stored != nil { accepted += 1 }
        }
        req.logger.debug("curation: stored \(accepted) of \(body.observations.count) observations")
        return SubmitObservationsResponse(accepted: accepted)
    }

    /// Each photo's hash, read from its asset row through this library, never
    /// taken from a request. An id the library doesn't hold has none.
    static func hashes(of assetIDs: [UUID], in spaceID: UUID, on sql: any SQLDatabase) async throws -> [UUID: String] {
        struct HashRow: Decodable { let id: UUID; let sha256: String }
        let hashes = try await sql.raw("""
            SELECT a.id, a.sha256
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.id = ANY(\(bind: assetIDs))
            """).all(decoding: HashRow.self)
        return Dictionary(hashes.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - The age written in a birthday photo

    /// The photos whose writing a person's devices read: a birthday by their
    /// devices' analysis or by the NAS's, and never a screenshot or document.
    /// Over the person's own `media_observations o`.
    static func birthdayPhoto(userID: UUID) -> SQLQueryString {
        """
        NOT o.is_utility AND NOT ('utility' = ANY(o.tags))
        AND ('birthday' = ANY(o.tags) OR EXISTS (
            SELECT 1 FROM nas_observations n
            WHERE n.user_id = \(bind: userID) AND n.sha256 = o.sha256
              AND 'birthday' = ANY(n.tags) AND NOT n.is_utility
        ))
        """
    }

    /// The caller's birthday photos whose writing their devices haven't read
    /// at this version, newest first: the ones that might say how old someone
    /// turned (`CollectionsController.writtenAge`).
    ///
    /// None for someone without People, whose birthdays aren't named for
    /// anyone and so never say an age, and none while curation is off. Only
    /// photos their devices have analyzed already, which is all of them once
    /// the regular pass has caught up.
    @Sendable
    func pendingWriting(req: Request) async throws -> PendingAnalysisResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let context = try await Self.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.isPersonal else { throw Abort(.notFound, reason: "No such space.") }
        guard context.enabled, context.showsPeople else { return PendingAnalysisResponse(items: [], remaining: 0) }

        let version = min(max(req.query[Int.self, at: "readingVersion"] ?? 1, 1), 1_000)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 8, 1), Self.maxBatch)
        let unread: SQLQueryString = """
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN media_observations o ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND (o.written_version IS NULL OR o.written_version < \(bind: version))
              AND \(Self.birthdayPhoto(userID: device.userID))
            """

        struct ItemRow: Decodable { let assetID: UUID; let thumbVersion: Int }
        let items = try await req.sql.raw("""
            SELECT a.id AS "assetID", a.thumb_version AS "thumbVersion"
            \(unread)
            ORDER BY \(unsafeRaw: TimelineController.localTime) DESC, a.id
            LIMIT \(bind: limit)
            """).all(decoding: ItemRow.self)
        struct CountRow: Decodable { let n: Int }
        let remaining = try await req.sql.raw("""
            SELECT count(*)::int AS n
            \(unread)
            """).first(decoding: CountRow.self)?.n ?? 0

        return PendingAnalysisResponse(
            items: items.map { PendingAnalysisItem(assetID: $0.assetID, thumbVersion: $0.thumbVersion) },
            remaining: remaining
        )
    }

    /// Stores the numbers a device read in the caller's birthday photos.
    ///
    /// As `submit` does: each photo is found through the caller's own library
    /// and its hash read from the asset row, so an id they can't see matches
    /// nothing. Kept only for a photo `pendingWriting` would list, and only
    /// whole numbers from 1 to 18. A photo already read at this version keeps
    /// its first answer; a newer version replaces an older one.
    @Sendable
    func submitWriting(req: Request) async throws -> SubmitObservationsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let context = try await Self.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.isPersonal else { throw Abort(.notFound, reason: "No such space.") }

        let body = try req.content.decode(SubmitWrittenNumbersRequest.self)
        guard body.photos.count <= Self.maxBatch else {
            throw Abort(.payloadTooLarge, reason: "At most \(Self.maxBatch) photos at a time.")
        }
        guard (1...1_000).contains(body.readingVersion) else {
            throw Abort(.badRequest, reason: "Unrecognized reading version.")
        }
        guard context.enabled, context.showsPeople else { return SubmitObservationsResponse(accepted: 0) }

        let hashByAsset = try await Self.hashes(of: body.photos.map(\.assetID), in: spaceID, on: req.sql)
        var accepted = 0
        for photo in body.photos {
            guard let sha256 = hashByAsset[photo.assetID] else { continue }
            let stored = try await req.sql.raw("""
                UPDATE media_observations o
                SET written = \(bind: Self.sanitized(numbers: photo.numbers))::smallint[],
                    written_version = \(bind: body.readingVersion)
                WHERE o.user_id = \(bind: device.userID) AND o.sha256 = \(bind: sha256)
                  AND (o.written_version IS NULL OR o.written_version < \(bind: body.readingVersion))
                  AND \(Self.birthdayPhoto(userID: device.userID))
                RETURNING o.sha256
                """).first()
            if stored != nil { accepted += 1 }
        }
        req.logger.debug("curation: stored the writing of \(accepted) of \(body.photos.count) photos")
        return SubmitObservationsResponse(accepted: accepted)
    }

    /// Whole numbers from 1 to 18, each once, smallest first, and no more
    /// than a photo could sensibly say.
    static func sanitized(numbers: [Int]) -> [Int] {
        Array(Set(numbers.filter { (1...18).contains($0) })).sorted().prefix(8).map { $0 }
    }

    /// The strongest few, with confidences clamped and names kept to what a
    /// Vision identifier can be.
    static func sanitized(_ labels: [ObservedLabel]) -> [ObservedLabel] {
        labels
            .filter { !$0.id.isEmpty && $0.id.count <= 64 && $0.confidence.isFinite }
            .map { ObservedLabel(id: $0.id, confidence: min(max($0.confidence, 0), 1)) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { $0 }
    }

    /// What the caller's own devices saw in one photo, for the Information
    /// panel. Any library the caller belongs to, since the answer is about the
    /// bytes and the caller's own analysis of them; 404 when there is none.
    @Sendable
    func observation(req: Request) async throws -> AssetObservationDetail {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        try await SpaceAccess.requireMembership(spaceID: spaceID, userID: device.userID, on: req.sql)

        struct Row: Decodable {
            let labels: String
            let aesthetic: Float?
            let isUtility: Bool
            let peopleCount: Int
            let animalCount: Int
            let tags: [String]
        }
        guard let row = try await req.sql.raw("""
            SELECT o.labels::text AS labels, o.aesthetic, o.is_utility AS "isUtility",
                   o.people_count::int AS "peopleCount", o.animal_count::int AS "animalCount",
                   o.tags
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN media_observations o ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
              AND sa.deleted_at IS NULL
            """).first(decoding: Row.self)
        else { throw Abort(.notFound, reason: "Not analyzed yet.") }

        let labels = (try? JSONDecoder().decode([ObservedLabel].self, from: Data(row.labels.utf8))) ?? []
        return AssetObservationDetail(
            labels: labels, aesthetic: row.aesthetic, isUtility: row.isUtility,
            peopleCount: row.peopleCount, animalCount: row.animalCount, tags: row.tags
        )
    }

    /// What the NAS's analyzer saw in one photo or video: the caller's own
    /// analysis of the file, in the same words as their devices'. 404 when
    /// there's none, which is also what anyone the NAS doesn't analyze gets.
    /// Labels, tags and a count of people; never anything about faces.
    @Sendable
    func nasObservation(req: Request) async throws -> NASObservationDetail {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        try await SpaceAccess.requireMembership(spaceID: spaceID, userID: device.userID, on: req.sql)

        struct Row: Decodable {
            let labels: String
            let tags: [String]
            let peopleCount: Int
            let frames: Int
        }
        guard let row = try await req.sql.raw("""
            SELECT o.labels::text AS labels, o.tags, o.people_count::int AS "peopleCount",
                   n.frames::int AS frames
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN nas_observations o ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            JOIN nas_analysis n ON n.user_id = o.user_id AND n.sha256 = o.sha256
            WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
              AND sa.deleted_at IS NULL
            """).first(decoding: Row.self)
        else { throw Abort(.notFound, reason: "Not analyzed by the NAS yet.") }

        let labels = (try? JSONDecoder().decode([ObservedLabel].self, from: Data(row.labels.utf8))) ?? []
        return NASObservationDetail(
            labels: Array(labels.prefix(12)), tags: row.tags,
            peopleCount: row.peopleCount, frames: row.frames
        )
    }
}

/// Whose observations a person's page and search read: their devices'
/// (`media_observations`), or the NAS's (`nas_observations`, the same
/// columns). The NAS's once they've switched to it, or while they preview it.
/// Covers, highlights and featured photos always read the devices', for
/// Vision's aesthetic scores.
enum ObservationSource: Sendable, Equatable {
    case devices, nas

    init(nas: String, preview: Bool) {
        self = nas == "on" || (preview && nas == "shadow") ? .nas : .devices
    }

    /// A constant, so safe to splice into a query.
    var table: String {
        switch self {
        case .devices: return "media_observations"
        case .nas: return "nas_observations"
        }
    }
}
