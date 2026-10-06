import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension SubmitObservationsRequest: @retroactive Content {}
extension SubmitObservationsResponse: @retroactive Content {}
extension PendingAnalysisResponse: @retroactive Content {}
extension CurationSettings: @retroactive Content {}
extension UpdateCurationSettingsRequest: @retroactive Content {}
extension CurationStatus: @retroactive Content {}
extension AssetObservationDetail: @retroactive Content {}

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
        protected.get("spaces", ":spaceID", "assets", ":assetID", "observation", use: observation)
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
    }

    /// The caller's settings, and whether this space is theirs to curate.
    static func context(
        userID: UUID, spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> Context {
        struct Row: Decodable {
            let enabled: Bool
            let holidays: Bool
            let isPersonal: Bool
        }
        let row = try await sql.raw("""
            SELECT u.curation_enabled AS enabled, u.curation_holidays AS holidays,
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
            isPersonal: row?.isPersonal ?? false
        )
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
            total: counts?.total ?? 0
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
                curation_holidays = COALESCE(\(bind: body.holidays)::boolean, curation_holidays)
            WHERE id = \(bind: device.userID)
            """).run()
        return try await settings(userID: device.userID, on: req.sql)
    }

    /// Forgets everything the caller's devices ever reported. The photographs
    /// themselves, their albums and anything named by hand are untouched.
    @Sendable
    func deleteData(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        try await req.sql.raw("""
            DELETE FROM media_observations WHERE user_id = \(bind: device.userID)
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

        struct HashRow: Decodable { let id: UUID; let sha256: String }
        let hashes = try await req.sql.raw("""
            SELECT a.id, a.sha256
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.id = ANY(\(bind: body.observations.map(\.assetID)))
            """).all(decoding: HashRow.self)
        let hashByAsset = Dictionary(hashes.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })

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
}
