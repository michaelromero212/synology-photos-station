import Crypto
import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// What the NAS's scene embeddings mean, in the words the phones use.
///
/// The analyzer stores SigLIP 2's view of each photo, and of each sampled
/// video frame, as 768 numbers (`nas_analysis.scene`). SigLIP's text side,
/// run once ahead of time, turned each Vision label the vocabulary uses into
/// a vector of its own (`Resources/scene-concepts.json`). A label's score is
/// SigLIP's own logit: `scale × cos(image, label) + bias`. A video counts as
/// showing what its strongest frame shows.
///
/// Calibration maps the scores onto the scale the vocabulary's thresholds were
/// written for. For each label it finds the logit at which the NAS calls as
/// many photos as Vision did, on photos both a phone and the NAS analyzed,
/// held between SigLIP probabilities of 0.0005 and 0.02. That logit reads as
/// 0.3. A label too rare to measure takes a probability of 0.002. Vision
/// decides how many; SigLIP decides which.
///
/// Those numbers are low because SigLIP 2's are, for one-thing prompts like
/// these: on the dev library's 105 photos the best probability per photo had
/// a median of 0.002, and a photo-to-concept cosine of 0.086 was already the
/// top 1% of all pairs. At 0.002 half the photos had a label, 1.2 on average
/// and 7 at most, much as the phones label the vocabulary's things.
///
/// Every number here is derived. Changing the concepts, the calibration or
/// the vocabulary re-scores what's stored; no file is analyzed twice.
struct SceneConcepts: Sendable {
    let model: String
    /// The vision tower these were made for, as the analyzer reports it
    /// (`siglip2-base-patch32-256@0ddb7507cfcb`). Scenes from any other
    /// model aren't scored.
    let visionModel: String
    let scale: Float
    let bias: Float
    let ids: [String]
    /// ids.count × dimensions, row-major, unit length.
    let vectors: [Float]
    let dimensions: Int
    /// Short hash of the file, so a new concept set re-scores everything.
    let version: String

    static func load() throws -> SceneConcepts {
        guard let url = Bundle.module.url(forResource: "scene-concepts", withExtension: "json") else {
            throw Abort(.internalServerError, reason: "scene-concepts.json is missing from the build")
        }
        let data = try Data(contentsOf: url)
        struct File: Decodable {
            struct Concept: Decodable { let id: String; let vector: String }
            let model: String
            let visionSHA256: String
            let logitScale: Float
            let logitBias: Float
            let dimensions: Int
            let concepts: [Concept]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var vectors: [Float] = []
        vectors.reserveCapacity(file.concepts.count * file.dimensions)
        for concept in file.concepts {
            guard let raw = AnalyzerClient.floats(concept.vector, count: file.dimensions) else {
                throw Abort(.internalServerError, reason: "concept \(concept.id) is malformed")
            }
            vectors.append(contentsOf: raw.littleEndianFloats())
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SceneConcepts(
            model: file.model,
            visionModel: "\(file.model)@\(file.visionSHA256.prefix(12))",
            scale: file.logitScale, bias: file.logitBias,
            ids: file.concepts.map(\.id), vectors: vectors, dimensions: file.dimensions,
            version: String(digest.prefix(12))
        )
    }

    /// Each concept's logit for one file: the highest over its frames.
    func logits(scene: [Float], frames: Int) -> [Float] {
        var best = [Float](repeating: -.infinity, count: ids.count)
        guard frames > 0, scene.count == frames * dimensions else { return best }
        scene.withUnsafeBufferPointer { scene in
            vectors.withUnsafeBufferPointer { concepts in
                for frame in 0..<frames {
                    let image = UnsafeBufferPointer(rebasing: scene[(frame * dimensions)..<((frame + 1) * dimensions)])
                    var norm: Float = 0
                    for x in image { norm += x * x }
                    let inverse = norm > 0 ? 1 / norm.squareRoot() : 0
                    for c in 0..<ids.count {
                        var dot: Float = 0
                        let base = c * dimensions
                        for d in 0..<dimensions { dot += image[d] * concepts[base + d] }
                        let logit = scale * dot * inverse + bias
                        if logit > best[c] { best[c] = logit }
                    }
                }
            }
        }
        return best
    }
}

/// Where each label's logit reads as 0.3. See `SceneConcepts`.
struct SceneCalibration: Sendable {
    /// The vocabulary's own threshold.
    static let anchor: Float = 0.3
    static let defaultProbability: Float = 0.002
    static let floorProbability: Float = 0.0005
    static let ceilingProbability: Float = 0.02
    /// Too little overlap, or too few photos Vision put a label on, and the
    /// default stands for that label.
    static let minimumOverlap = 300
    static let minimumPositives = 5

    let thresholds: [String: Float]
    /// Short hash of the thresholds, so a recalibration re-scores.
    let generation: String

    static let uncalibrated = SceneCalibration(thresholds: [:])

    init(thresholds: [String: Float]) {
        self.thresholds = thresholds
        let text = thresholds.keys.sorted().map { "\($0)=\(String(format: "%.3f", thresholds[$0]!))" }
            .joined(separator: ",")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        generation = thresholds.isEmpty ? "default" : String(digest.prefix(12))
    }

    static func logit(_ p: Float) -> Float { log(p / (1 - p)) }

    func threshold(for label: String) -> Float {
        thresholds[label] ?? Self.logit(Self.defaultProbability)
    }

    /// The confidence the vocabulary reads, on its own scale: 0.3 at the
    /// label's threshold.
    func confidence(logit: Float, label: String) -> Float {
        let shifted = logit - threshold(for: label) + Self.logit(Self.anchor)
        return 1 / (1 + exp(-shifted))
    }

    /// The logit at which the NAS calls as many photos as Vision did.
    /// `logits` are the NAS's for one label over the overlap; `positives`
    /// how many of the same photos Vision put at the anchor or above.
    static func threshold(logits: [Float], positives: Int) -> Float? {
        guard logits.count >= minimumOverlap, positives >= minimumPositives else { return nil }
        let sorted = logits.sorted(by: >)
        let matched = sorted[min(positives, sorted.count) - 1]
        return min(max(matched, logit(floorProbability)), logit(ceilingProbability))
    }
}

/// One file's observation, from its scene and its faces.
enum NASScoring {
    /// As on the phones: below this a label isn't kept, and only the strongest
    /// are.
    static let labelFloor: Float = 0.1
    static let maxLabels = 40
    /// A face this small is a speck in a crowd, not a person someone's with.
    static let gatheringFacePixels = 24

    struct Observation: Sendable {
        let labels: [ObservedLabel]
        let tags: [String]
        let terms: [String]
        let words: [String]
        let peopleCount: Int
    }

    static func observation(
        logits: [Float], concepts: SceneConcepts, calibration: SceneCalibration, peopleCount: Int
    ) -> Observation {
        var labels: [ObservedLabel] = []
        for (index, id) in concepts.ids.enumerated() where logits[index].isFinite {
            let confidence = calibration.confidence(logit: logits[index], label: id)
            if confidence >= labelFloor {
                labels.append(ObservedLabel(id: id, confidence: (confidence * 1000).rounded() / 1000))
            }
        }
        labels.sort { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.id < $1.id }
        labels = Array(labels.prefix(maxLabels))
        let tags = CurationVocabulary.tags(for: labels, peopleCount: peopleCount)
        let terms = CurationVocabulary.terms(labels: labels, tags: tags)
        return Observation(
            labels: labels, tags: tags, terms: terms,
            words: CurationVocabulary.words(of: terms), peopleCount: peopleCount
        )
    }
}

extension Data {
    /// Little-endian float32s, as the analyzer and the concept file write them.
    func littleEndianFloats() -> [Float] {
        withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
    }
}

/// Keeps `nas_observations` current: scores each file as it's analyzed,
/// recalibrates as the overlap with the phones grows, and re-scores whatever
/// an older concept set, calibration or vocabulary produced.
actor NASScorer {
    private let app: Application
    private let concepts: SceneConcepts
    private var calibration = SceneCalibration.uncalibrated
    private var calibratedOverlap = 0
    private var lastCalibration: ContinuousClock.Instant?
    private var task: Task<Void, Never>?

    init(app: Application, concepts: SceneConcepts) {
        self.app = app
        self.concepts = concepts
    }

    var scoring: String { "\(concepts.version)/\(calibration.generation)" }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        await loadCalibration()
        while !Task.isCancelled {
            do {
                try await recalibrateIfDue()
                try await rescoreStale()
            } catch is CancellationError {
                return
            } catch {
                app.logger.error("analysis: scoring stopped: \(String(reflecting: error))")
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    // MARK: - One file

    private struct Stored: Decodable {
        let userID: UUID
        let sha256: String
        let models: String
        let frames: Int
        let scene: Data?
        let people: Int
    }

    /// Scores one file just analyzed. Never throws: a file left unscored is
    /// picked up by the next pass.
    func score(userID: UUID, sha256: String) async {
        do {
            let rows = try await stored(where: "n.user_id = \(bind: userID) AND n.sha256 = \(bind: sha256)")
            for row in rows { try await save(row) }
        } catch {
            app.logger.error("analysis: couldn't score \(sha256.prefix(8)): \(String(reflecting: error))")
        }
    }

    private func stored(where condition: SQLQueryString, limit: Int = 1) async throws -> [Stored] {
        try await app.sql.raw("""
            SELECT n.user_id AS "userID", n.sha256, n.models, n.frames, n.scene,
                   COALESCE((SELECT max(c)::int FROM (
                       SELECT count(*) AS c FROM nas_faces f
                       WHERE f.user_id = n.user_id AND f.sha256 = n.sha256
                         AND f.size_px >= \(bind: NASScoring.gatheringFacePixels)
                       GROUP BY f.frame) per_frame), 0) AS people
            FROM nas_analysis n
            WHERE n.status = 'done' AND \(condition)
            LIMIT \(bind: limit)
            """).all(decoding: Stored.self)
    }

    private func save(_ row: Stored) async throws {
        // Scenes from another model would be scored against the wrong
        // vectors; they wait for concepts made from theirs.
        guard row.models.contains("scene=\(concepts.visionModel)"), let scene = row.scene else { return }
        let logits = concepts.logits(scene: scene.littleEndianFloats(), frames: row.frames)
        let observation = NASScoring.observation(
            logits: logits, concepts: concepts, calibration: calibration, peopleCount: row.people
        )
        let labels = String(decoding: try JSONEncoder().encode(observation.labels), as: UTF8.self)
        try await app.sql.raw("""
            INSERT INTO nas_observations
                (user_id, sha256, labels, people_count, tags, terms, words,
                 vocabulary_version, scoring, scored_at)
            VALUES (\(bind: row.userID), \(bind: row.sha256), \(bind: labels)::jsonb,
                    \(bind: observation.peopleCount), \(bind: observation.tags),
                    \(bind: observation.terms), \(bind: observation.words),
                    \(bind: CurationVocabulary.version), \(bind: scoring), now())
            ON CONFLICT (user_id, sha256) DO UPDATE SET
                labels = EXCLUDED.labels, people_count = EXCLUDED.people_count,
                tags = EXCLUDED.tags, terms = EXCLUDED.terms, words = EXCLUDED.words,
                vocabulary_version = EXCLUDED.vocabulary_version,
                scoring = EXCLUDED.scoring, scored_at = now()
            """).run()
    }

    /// Whatever an older concept set, calibration or vocabulary scored, a
    /// page at a time, paced so the app's requests come first.
    private func rescoreStale() async throws {
        var done = 0
        while !Task.isCancelled {
            let rows = try await stored(where: """
                NOT EXISTS (
                    SELECT 1 FROM nas_observations o
                    WHERE o.user_id = n.user_id AND o.sha256 = n.sha256
                      AND o.scoring = \(bind: scoring)
                      AND o.vocabulary_version = \(bind: CurationVocabulary.version))
                AND n.models LIKE \(bind: "%scene=\(concepts.visionModel)%")
                """, limit: 200)
            if rows.isEmpty { break }
            for row in rows { try await save(row) }
            done += rows.count
            try await Task.sleep(for: .milliseconds(50))
        }
        if done > 0 {
            app.logger.info("analysis: scored \(done) files with \(scoring)")
        }
    }

    // MARK: - Calibration

    private struct Threshold: Decodable {
        let label: String
        let threshold: Float
        let overlap: Int
    }

    private func loadCalibration() async {
        do {
            let rows = try await app.sql.raw("""
                SELECT label, threshold, overlap FROM nas_calibration
                """).all(decoding: Threshold.self)
            calibration = SceneCalibration(thresholds: Dictionary(
                rows.filter { concepts.ids.contains($0.label) }.map { ($0.label, $0.threshold) },
                uniquingKeysWith: { first, _ in first }
            ))
            calibratedOverlap = rows.first?.overlap ?? 0
        } catch {
            app.logger.error("analysis: couldn't read the calibration: \(error)")
        }
    }

    /// Photos both a phone and the NAS analyzed, the newest first, at most
    /// this many: enough to measure, and a bounded amount of memory. `overlap`
    /// in the table is how many there were in all, which is what the next
    /// recalibration compares against.
    static let calibrationSample = 20_000

    /// Recalibrates when the overlap has grown by a quarter since the last
    /// time, at most every six hours.
    private func recalibrateIfDue() async throws {
        if let last = lastCalibration, ContinuousClock.now - last < .seconds(6 * 3600) { return }
        struct Count: Decodable { let count: Int }
        let overlap = try await app.sql.raw("""
            SELECT count(*)::int AS count
            FROM nas_analysis n
            JOIN media_observations m ON m.user_id = n.user_id AND m.sha256 = n.sha256
            WHERE n.status = 'done' AND n.frames = 1
              AND n.models LIKE \(bind: "%scene=\(concepts.visionModel)%")
            """).first(decoding: Count.self)?.count ?? 0
        guard overlap >= SceneCalibration.minimumOverlap,
              Double(overlap) >= Double(calibratedOverlap) * 1.25
        else { return }
        lastCalibration = ContinuousClock.now

        struct Row: Decodable {
            let scene: Data
            let labels: String
        }
        var perLabel = [[Float]](repeating: [], count: concepts.ids.count)
        var positives = [Int](repeating: 0, count: concepts.ids.count)
        let index = Dictionary(uniqueKeysWithValues: concepts.ids.enumerated().map { ($1, $0) })
        var seen = 0
        var offset = 0
        // Files analyzed while this runs would shift the pages under it.
        let cutoff = Date()
        while seen < Self.calibrationSample {
            let rows = try await app.sql.raw("""
                SELECT n.scene, m.labels::text AS labels
                FROM nas_analysis n
                JOIN media_observations m ON m.user_id = n.user_id AND m.sha256 = n.sha256
                WHERE n.status = 'done' AND n.frames = 1 AND n.scene IS NOT NULL
                  AND n.models LIKE \(bind: "%scene=\(concepts.visionModel)%")
                  AND n.analyzed_at <= \(bind: cutoff)
                ORDER BY n.analyzed_at DESC, n.sha256
                LIMIT 500 OFFSET \(bind: offset)
                """).all(decoding: Row.self)
            if rows.isEmpty { break }
            for row in rows {
                let logits = concepts.logits(scene: row.scene.littleEndianFloats(), frames: 1)
                for c in 0..<logits.count { perLabel[c].append(logits[c]) }
                let device = (try? JSONDecoder().decode([ObservedLabel].self, from: Data(row.labels.utf8))) ?? []
                for label in device where label.confidence >= SceneCalibration.anchor {
                    if let c = index[label.id] { positives[c] += 1 }
                }
            }
            seen += rows.count
            offset += rows.count
            try await Task.sleep(for: .milliseconds(20))
        }

        var thresholds: [String: Float] = [:]
        for (c, id) in concepts.ids.enumerated() {
            if let threshold = SceneCalibration.threshold(logits: perLabel[c], positives: positives[c]) {
                thresholds[id] = threshold
            }
        }
        let sampled = seen
        let counted = overlap
        let rows = thresholds.keys.sorted().map { (label: $0, threshold: thresholds[$0]!, positives: positives[index[$0]!]) }
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("DELETE FROM nas_calibration").run()
                for row in rows {
                    try await sql.raw("""
                        INSERT INTO nas_calibration (label, threshold, positives, overlap)
                        VALUES (\(bind: row.label), \(bind: row.threshold), \(bind: row.positives), \(bind: counted))
                        """).run()
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        calibration = SceneCalibration(thresholds: thresholds)
        calibratedOverlap = counted
        app.logger.info("analysis: calibrated \(thresholds.count) of \(concepts.ids.count) labels against \(sampled) photos a phone also analyzed")
    }
}

struct NASScorerKey: StorageKey {
    typealias Value = NASScorer
}
