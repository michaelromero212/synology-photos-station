import Dispatch
import Foundation
import SQLKit
import Vapor

/// Groups the faces in each person's library into the people in it, and keeps
/// "Is this Emma?" current. See NAS-ANALYSIS.md §6–7 and migration 0038.
///
/// SFace's numbers for two pictures of one person sit closer together than
/// for two people. Each face is compared with each person's average face (the
/// centroid), never with another library's:
/// - **Close** (cosine ≥ `join`) joins that person on its own. Strong matches
///   are named automatically once the person has a name.
/// - **Near** (≥ `suggest`) to someone the person named becomes a question
///   for them.
/// - **Neither** waits. Enough of those like each other (`newPersonFaces`
///   faces in `newPersonFiles` files) become a new, unnamed person.
///
/// The person's word is final:
/// - two faces in one photo are never one person;
/// - a face they said no to never joins that person again;
/// - two people they named are never merged by the NAS;
/// - nothing they confirmed is undone here.
///
/// Faces are read sealed and opened only in memory; nothing biometric is
/// logged or written outside `nas_faces`. Deterministic: the same faces in the
/// same order give the same groups.
///
/// **Cost.** Faces that wait are compared with every group so far, and most
/// strangers are a group of one, so a pass grows with the square of the faces
/// waiting. Measured on a Mac with stand-in faces, 40% of them strangers: 0.24 s
/// for 10,000 faces, 1.5 s for 25,000, 3.8 s for 40,000; expect several times
/// that on the NAS's Celeron. (Before the faces sat in one buffer, with each
/// centroid's length kept and the same-frame check made only for a winner,
/// 10,000 took 5.6 s.) So the grouping runs off this actor, on a utility
/// queue, and while the NAS is still working through a library it regroups at
/// most every `settle`. Something the person decided doesn't wait for that.
actor PeopleClusterer {
    static let join: Float = 0.50
    /// A small face is a blurrier one, so it has to be closer to join.
    static let joinSmall: Float = 0.56
    static let suggest: Float = 0.40
    /// Two unnamed groups this alike are one person.
    static let merge: Float = 0.62
    static let minScore: Float = 0.85
    /// Faces at least this big (in the 1,280-pixel render) can start a person.
    static let seedPixels = 40
    static let minPixels = 24
    static let newPersonFaces = 4
    static let newPersonFiles = 3
    static let maxSuggestions = 60
    /// SFace's numbers per face.
    static let dimensions = 128

    private let app: Application
    private let seal: FaceSeal
    private let startDelay: Duration
    private let interval: Duration
    private let settle: Duration
    private var seen: [UUID: Int] = [:]
    private var lastPass: [UUID: ContinuousClock.Instant] = [:]
    private var dirty: Set<UUID> = []
    private var task: Task<Void, Never>?

    /// The smoke tests shorten all three.
    init(
        app: Application, seal: FaceSeal, startDelay: Duration = .seconds(45),
        interval: Duration = .seconds(60), settle: Duration = .seconds(900)
    ) {
        self.app = app
        self.seal = seal
        self.startDelay = startDelay
        self.interval = interval
        self.settle = settle
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Something the person decided; regroup soon.
    func touch(_ userID: UUID) {
        dirty.insert(userID)
    }

    private func run() async {
        try? await Task.sleep(for: startDelay)
        while !Task.isCancelled {
            do {
                struct Row: Decodable { let id: UUID; let faces: Int }
                let rows = try await app.sql.raw("""
                    SELECT u.id, (SELECT count(*)::int FROM nas_faces f WHERE f.user_id = u.id) AS faces
                    FROM users u
                    WHERE u.nas_analysis <> 'off' AND u.deleted_at IS NULL
                    """).all(decoding: Row.self)
                for row in rows where Task.isCancelled == false {
                    // New faces arrive all day while the NAS works through a
                    // library; they're grouped every `settle`, not each minute.
                    let changed = seen[row.id] != row.faces
                    let due = lastPass[row.id].map { ContinuousClock.now - $0 >= settle } ?? true
                    if dirty.contains(row.id) || (changed && due) {
                        dirty.remove(row.id)
                        try await refresh(userID: row.id)
                        seen[row.id] = row.faces
                        lastPass[row.id] = .now
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                app.logger.error("people: grouping stopped: \(String(reflecting: error))")
            }
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - One library

    /// One face, without its numbers: those are in `Library.vectors`.
    struct Face: Sendable {
        let sha256: String
        let ordinal: Int
        let box: [Float]
        let pixels: Int
        /// The file, and the frame within it, as small numbers.
        let file: Int
        let frame: Int
        var key: String { "\(sha256)#\(ordinal)" }
    }

    /// Everything one pass needs, read from the database and opened.
    struct Library: Sendable {
        var faces: [Face] = []
        /// Each face's numbers, `dimensions` to a face in `faces`' order,
        /// each face of unit length.
        var vectors: [Float] = []
        /// Everyone so far, in a fixed order.
        var people: [UUID] = []
        var named: Set<UUID> = []
        /// Faces that are someone's already, as indexes into `faces` and
        /// `people`.
        var members: [(face: Int, person: Int)] = []
        /// Faces the person said aren't someone.
        var rejected: [Int: Set<UUID>] = [:]
    }

    /// What one pass decided, before any of it is written.
    struct Plan: Sendable {
        var newAuto: [(face: Int, person: UUID, similarity: Float)] = []
        var created: [(id: UUID, faces: [Int])] = []
        var merges: [(from: UUID, into: UUID)] = []
        var suggestions: [(face: Int, person: UUID, similarity: Float)] = []
    }

    private struct Membership: Decodable {
        let sha256: String
        let ordinal: Int
        let personID: UUID
        let state: String
    }

    func refresh(userID: UUID) async throws {
        let started = ContinuousClock.now
        var library = try await loadFaces(userID)
        let byKey = Dictionary(uniqueKeysWithValues: library.faces.indices.map { (library.faces[$0].key, $0) })

        struct PersonRow: Decodable { let id: UUID; let named: Bool }
        let personRows = try await app.sql.raw("""
            SELECT id, name IS NOT NULL AS named FROM people WHERE user_id = \(bind: userID)
            """).all(decoding: PersonRow.self)
        let memberships = try await app.sql.raw("""
            SELECT sha256, ordinal::int AS ordinal, person_id AS "personID", state
            FROM person_faces WHERE user_id = \(bind: userID)
            """).all(decoding: Membership.self)

        let sorted = personRows.sorted { $0.id.uuidString < $1.id.uuidString }
        library.people = sorted.map(\.id)
        library.named = Set(sorted.filter(\.named).map(\.id))
        let personIndex = Dictionary(uniqueKeysWithValues: library.people.enumerated().map { ($1, $0) })
        var orphans: [Membership] = []
        for m in memberships {
            guard let face = byKey["\(m.sha256)#\(m.ordinal)"] else {
                orphans.append(m)
                continue
            }
            switch m.state {
            case "auto", "confirmed":
                if let person = personIndex[m.personID] { library.members.append((face, person)) }
            case "rejected":
                library.rejected[face, default: []].insert(m.personID)
            default:
                break
            }
        }

        // Off this actor, so a person naming someone never waits on a pass.
        let input = library
        let plan = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.plan(input))
            }
        }

        try await write(userID: userID, library: library, plan: plan, orphans: orphans)
        let elapsed = ContinuousClock.now - started
        let ms = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        if !plan.newAuto.isEmpty || !plan.created.isEmpty || !plan.merges.isEmpty {
            app.logger.info("people: \(plan.newAuto.count) faces placed, \(plan.created.count) new people, \(plan.merges.count) merged, \(plan.suggestions.count) questions, \(library.faces.count) faces in \(ms) ms")
        }
    }

    // MARK: - Grouping

    /// Centroids side by side: each one's running sum and the inverse of its
    /// length, kept as faces join so a comparison is one dot product, and
    /// which frames and files are in it.
    struct Centroids {
        private(set) var sums: [Float] = []
        private(set) var inverseNorms: [Float] = []
        private(set) var counts: [Int] = []
        private(set) var frames: [Set<Int>] = []
        private(set) var files: [Set<Int>] = []
        private(set) var members: [[Int]] = []
        var ids: [UUID?] = []
        var named: [Bool] = []
        var count: Int { counts.count }

        mutating func append(id: UUID?, named isNamed: Bool) -> Int {
            sums.append(contentsOf: repeatElement(0, count: PeopleClusterer.dimensions))
            inverseNorms.append(0)
            counts.append(0)
            frames.append([])
            files.append([])
            members.append([])
            ids.append(id)
            named.append(isNamed)
            return count - 1
        }

        mutating func add(_ face: Int, to g: Int, faces: [Face], vectors: UnsafePointer<Float>) {
            let d = PeopleClusterer.dimensions
            var norm2: Float = 0
            sums.withUnsafeMutableBufferPointer { sum in
                for i in 0..<d { sum[g * d + i] += vectors[face * d + i] }
                for i in 0..<d { norm2 += sum[g * d + i] * sum[g * d + i] }
            }
            inverseNorms[g] = norm2 > 0 ? 1 / norm2.squareRoot() : 0
            counts[g] += 1
            frames[g].insert(faces[face].frame)
            files[g].insert(faces[face].file)
            members[g].append(face)
        }

        mutating func absorb(_ other: Int, into g: Int) {
            let d = PeopleClusterer.dimensions
            var norm2: Float = 0
            sums.withUnsafeMutableBufferPointer { sum in
                for i in 0..<d { sum[g * d + i] += sum[other * d + i] }
                for i in 0..<d { norm2 += sum[g * d + i] * sum[g * d + i] }
            }
            inverseNorms[g] = norm2 > 0 ? 1 / norm2.squareRoot() : 0
            counts[g] += counts[other]
            frames[g].formUnion(frames[other])
            files[g].formUnion(files[other])
            members[g] += members[other]
        }

        /// Cosine between a centroid and a face's unit vector.
        func similarity(_ g: Int, to face: UnsafeRawPointer) -> Float {
            guard counts[g] > 0 else { return -1 }
            return sums.withUnsafeBufferPointer { sum in
                PeopleClusterer.dot(UnsafeRawPointer(sum.baseAddress!) + g * PeopleClusterer.dimensions * 4, face)
            } * inverseNorms[g]
        }

        /// Cosine between two centroids.
        func similarity(_ a: Int, _ b: Int) -> Float {
            sums.withUnsafeBufferPointer { sum in
                let base = UnsafeRawPointer(sum.baseAddress!)
                let stride = PeopleClusterer.dimensions * 4
                return PeopleClusterer.dot(base + a * stride, base + b * stride)
            } * inverseNorms[a] * inverseNorms[b]
        }
    }

    /// One 128-number dot product, eight at a time.
    @inline(__always)
    static func dot(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Float {
        var s0 = SIMD8<Float>(repeating: 0), s1 = s0, s2 = s0, s3 = s0
        var offset = 0
        while offset < dimensions * 4 {
            s0 += a.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                * b.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
            s1 += a.loadUnaligned(fromByteOffset: offset + 32, as: SIMD8<Float>.self)
                * b.loadUnaligned(fromByteOffset: offset + 32, as: SIMD8<Float>.self)
            s2 += a.loadUnaligned(fromByteOffset: offset + 64, as: SIMD8<Float>.self)
                * b.loadUnaligned(fromByteOffset: offset + 64, as: SIMD8<Float>.self)
            s3 += a.loadUnaligned(fromByteOffset: offset + 96, as: SIMD8<Float>.self)
                * b.loadUnaligned(fromByteOffset: offset + 96, as: SIMD8<Float>.self)
            offset += 128
        }
        return (s0 + s1 + s2 + s3).sum()
    }

    /// One pass over one library: who each new face is, who's new, who's
    /// the same person, and what to ask. Pure, so it can run anywhere.
    static func plan(_ library: Library) -> Plan {
        var plan = Plan()
        let faces = library.faces
        guard !faces.isEmpty, library.vectors.count == faces.count * dimensions else { return plan }
        var centroids = Centroids()
        for id in library.people { _ = centroids.append(id: id, named: library.named.contains(id)) }
        let known = centroids.count

        library.vectors.withUnsafeBufferPointer { buffer in
            let vectors = buffer.baseAddress!
            let raw = UnsafeRawPointer(vectors)
            func vector(_ face: Int) -> UnsafeRawPointer { raw + face * dimensions * 4 }

            var placed = [Bool](repeating: false, count: faces.count)
            for m in library.members {
                centroids.add(m.face, to: m.person, faces: faces, vectors: vectors)
                placed[m.face] = true
            }

            // Faces no one has yet, each to the closest person it's close
            // enough to. The first of equals wins.
            var waiting: [Int] = []
            for f in faces.indices where !placed[f] {
                let needed = faces[f].pixels >= seedPixels ? join : joinSmall
                let excluded = library.rejected[f] ?? []
                var best: (g: Int, similarity: Float)?
                for g in 0..<known {
                    let s = centroids.similarity(g, to: vector(f))
                    guard s >= needed, s > (best?.similarity ?? -1) else { continue }
                    guard !centroids.frames[g].contains(faces[f].frame),
                          let id = centroids.ids[g], !excluded.contains(id)
                    else { continue }
                    best = (g, s)
                }
                if let best, let id = centroids.ids[best.g] {
                    centroids.add(f, to: best.g, faces: faces, vectors: vectors)
                    placed[f] = true
                    plan.newAuto.append((f, id, best.similarity))
                } else if faces[f].pixels >= seedPixels {
                    waiting.append(f)
                }
            }

            // The rest, grouped among themselves; big enough groups become
            // people. The last of equals wins.
            let firstGroup = centroids.count
            for f in waiting {
                var best = -1
                var bestSimilarity = join
                for g in firstGroup..<centroids.count {
                    let s = centroids.similarity(g, to: vector(f))
                    if s >= bestSimilarity, !centroids.frames[g].contains(faces[f].frame) {
                        bestSimilarity = s
                        best = g
                    }
                }
                if best < 0 { best = centroids.append(id: nil, named: false) }
                centroids.add(f, to: best, faces: faces, vectors: vectors)
            }
            var people = Array(0..<known)
            for g in firstGroup..<centroids.count
            where centroids.counts[g] >= newPersonFaces && centroids.files[g].count >= newPersonFiles {
                let id = UUID()
                centroids.ids[g] = id
                plan.created.append((id, centroids.members[g]))
                for face in centroids.members[g] { placed[face] = true }
                people.append(g)
            }

            // Unnamed people this alike are one. Never two named ones.
            let unnamed = people.filter { !centroids.named[$0] }
            var gone = Set<Int>()
            outer: for (i, a) in unnamed.enumerated() where !gone.contains(a) {
                for b in unnamed[(i + 1)...] where !gone.contains(b) {
                    guard centroids.counts[a] > 0, centroids.counts[b] > 0,
                          centroids.frames[a].isDisjoint(with: centroids.frames[b]),
                          centroids.similarity(a, b) >= merge,
                          let idA = centroids.ids[a], let idB = centroids.ids[b]
                    else { continue }
                    let (into, from) = centroids.counts[a] >= centroids.counts[b] ? (a, b) : (b, a)
                    plan.merges.append((from: from == a ? idA : idB, into: into == a ? idA : idB))
                    gone.insert(from)
                    centroids.absorb(from, into: into)
                    // Gone into someone else: nothing more to compare it with.
                    if from == a { continue outer }
                }
            }

            // Questions for the people they named.
            let named = (0..<known).filter { centroids.named[$0] && !gone.contains($0) }
            guard !named.isEmpty else { return }
            var perPerson: [UUID: [(face: Int, similarity: Float)]] = [:]
            for f in faces.indices where !placed[f] && faces[f].pixels >= minPixels {
                let excluded = library.rejected[f] ?? []
                var best: (id: UUID, similarity: Float)?
                for g in named {
                    let s = centroids.similarity(g, to: vector(f))
                    guard s >= suggest, s > (best?.similarity ?? -1) else { continue }
                    guard !centroids.frames[g].contains(faces[f].frame),
                          let id = centroids.ids[g], !excluded.contains(id)
                    else { continue }
                    best = (id, s)
                }
                if let best { perPerson[best.id, default: []].append((f, best.similarity)) }
            }
            for (id, list) in perPerson {
                for (face, s) in list.sorted(by: { $0.similarity > $1.similarity }).prefix(maxSuggestions) {
                    plan.suggestions.append((face, id, s))
                }
            }
        }
        return plan
    }

    /// Made-up faces for `analysis time-grouping`: people whose faces sit at
    /// cosine 0.65–0.85 to them, as one person's do, and four in ten faces
    /// strangers seen once, one to four faces a file. The same every time.
    static func standIn(faces count: Int) -> Library {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        func uniform() -> Float { Float(next() % 1_000_000) / 1_000_000 }
        func unitVector() -> [Float] {
            let v = (0..<dimensions).map { _ in
                (-2 * log(max(uniform(), 1e-7))).squareRoot() * cos(2 * .pi * uniform())
            }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return v.map { $0 / norm }
        }
        let identities = (0..<max(10, count / 100)).map { _ in unitVector() }
        var library = Library()
        var file = 0
        while library.faces.count < count {
            let sha = String(format: "%064llx", UInt64(file) &* 0x9E37_79B9_7F4A_7C15)
            for ordinal in 0..<(1 + Int(next() % 4)) where library.faces.count < count {
                let noise = unitVector()
                var vector = noise
                if uniform() >= 0.4 {
                    let identity = identities[Int(next() % UInt64(identities.count))]
                    let c = 0.65 + 0.2 * uniform()
                    vector = (0..<dimensions).map { c * identity[$0] + (1 - c * c).squareRoot() * noise[$0] }
                    let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    vector = vector.map { $0 / norm }
                }
                library.vectors += vector
                library.faces.append(Face(sha256: sha, ordinal: ordinal, box: [0, 0, 0.1, 0.1],
                                          pixels: 40 + Int(next() % 200), file: file, frame: file))
            }
            file += 1
        }
        return library
    }

    private func loadFaces(_ userID: UUID) async throws -> Library {
        struct Row: Decodable {
            let sha256: String
            let ordinal: Int
            let frame: Int
            let box: [Float]
            let score: Float
            let pixels: Int
            let embedding: Data
        }
        let rows = try await app.sql.raw("""
            SELECT f.sha256, f.ordinal::int AS ordinal, f.frame::int AS frame, f.box, f.score,
                   f.size_px::int AS pixels, f.embedding
            FROM nas_faces f
            JOIN nas_analysis n ON n.user_id = f.user_id AND n.sha256 = f.sha256
            WHERE f.user_id = \(bind: userID) AND n.status = 'done'
              AND f.score >= \(bind: Self.minScore) AND f.size_px >= \(bind: Self.minPixels)
            ORDER BY f.sha256, f.ordinal
            """).all(decoding: Row.self)
        var library = Library()
        library.faces.reserveCapacity(rows.count)
        library.vectors.reserveCapacity(rows.count * Self.dimensions)
        var files: [String: Int] = [:]
        var frames: [String: Int] = [:]
        for row in rows {
            guard let plain = try? seal.open(row.embedding, userID: userID, sha256: row.sha256, ordinal: row.ordinal),
                  plain.count == Self.dimensions * 4
            else { continue }
            let vector = plain.littleEndianFloats()
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            library.vectors += vector.map { $0 / norm }
            let file = files[row.sha256] ?? files.count
            files[row.sha256] = file
            let frameKey = "\(row.sha256)#\(row.frame)"
            let frame = frames[frameKey] ?? frames.count
            frames[frameKey] = frame
            library.faces.append(Face(sha256: row.sha256, ordinal: row.ordinal, box: row.box,
                                      pixels: row.pixels, file: file, frame: frame))
        }
        return library
    }

    // MARK: - Writing it down

    private func write(userID: UUID, library: Library, plan: Plan, orphans: [Membership]) async throws {
        typealias Row = (sha: String, ordinal: Int, person: UUID, state: String, similarity: Float?, box: [Float])
        let faces = library.faces
        var rows: [Row] = []
        for (face, id, s) in plan.newAuto {
            rows.append((faces[face].sha256, faces[face].ordinal, id, "auto", s, faces[face].box))
        }
        for (id, members) in plan.created {
            for face in members { rows.append((faces[face].sha256, faces[face].ordinal, id, "auto", nil, faces[face].box)) }
        }
        let suggested: [Row] = plan.suggestions.map { face, id, s in
            (faces[face].sha256, faces[face].ordinal, id, "suggested", s, faces[face].box)
        }
        let newPeople = plan.created.map(\.id)
        let merges = plan.merges
        let lost = orphans.filter { $0.state == "auto" || $0.state == "suggested" }
        let inserts = rows + suggested

        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                for id in newPeople {
                    try await sql.raw("""
                        INSERT INTO people (id, user_id) VALUES (\(bind: id), \(bind: userID))
                        """).run()
                }
                // The questions are asked afresh each time.
                try await sql.raw("""
                    DELETE FROM person_faces WHERE user_id = \(bind: userID) AND state = 'suggested'
                    """).run()
                // A few hundred to a statement: a first pass places thousands.
                for start in stride(from: 0, to: inserts.count, by: 500) {
                    let values: [SQLQueryString] = inserts[start..<min(start + 500, inserts.count)].map { row in
                        """
                        (\(bind: userID), \(bind: row.sha), \(bind: row.ordinal), \(bind: row.person), \
                        \(bind: row.state), \(bind: row.similarity), \(bind: AnalysisWorker.realArray(row.box))::real[])
                        """
                    }
                    try await sql.raw("""
                        INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box)
                        VALUES \(values.joined(separator: ", "))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
                for merge in merges {
                    try await sql.raw("""
                        INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box, decided_at)
                        SELECT user_id, sha256, ordinal, \(bind: merge.into), state, similarity, box, decided_at
                        FROM person_faces WHERE person_id = \(bind: merge.from)
                        ON CONFLICT DO NOTHING
                        """).run()
                    try await sql.raw("""
                        DELETE FROM people WHERE id = \(bind: merge.from) AND user_id = \(bind: userID) AND name IS NULL
                        """).run()
                }
                // Faces that are no longer there: what the NAS decided goes;
                // what the person decided stays until the file itself does.
                for m in lost {
                    try await sql.raw("""
                        DELETE FROM person_faces
                        WHERE user_id = \(bind: userID) AND sha256 = \(bind: m.sha256)
                          AND ordinal = \(bind: m.ordinal) AND person_id = \(bind: m.personID)
                        """).run()
                }
                try await sql.raw("""
                    DELETE FROM person_faces pf
                    WHERE pf.user_id = \(bind: userID)
                      AND NOT EXISTS (SELECT 1 FROM nas_analysis n
                                      WHERE n.user_id = pf.user_id AND n.sha256 = pf.sha256)
                    """).run()
                // A person with no faces left is no one.
                try await sql.raw("""
                    DELETE FROM people p
                    WHERE p.user_id = \(bind: userID) AND p.name IS NULL
                      AND NOT EXISTS (SELECT 1 FROM person_faces pf
                                      WHERE pf.person_id = p.id AND pf.state IN ('auto', 'confirmed'))
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}

struct PeopleClustererKey: StorageKey {
    typealias Value = PeopleClusterer
}
