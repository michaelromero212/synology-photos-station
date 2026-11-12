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
/// **Looks** (only with `looks` switched on, `FRAMESTATION_PEOPLE_LOOKS`).
/// One average face blurs a person who looks different over the years: a
/// toddler and the same child at eight, with and without glasses. Once a big
/// person absorbs a smaller group of their other look, that look is almost
/// lost in the average, and new faces of it start yet another unnamed group.
/// So each pass also sorts each person's own faces into looks, the groups
/// they would have formed on their own, and a face may join a person by its
/// closest look as well as by the average. A look that is as like someone
/// else as it is like its own person's main look is set aside, so a few of a
/// sibling's faces that crept in can't pull in the rest of the sibling.
/// Someone else is anyone named, or anyone in a photo with the person; an
/// unnamed group never seen with them may be one more look of theirs. Looks
/// are worked out afresh each pass and never stored.
///
/// **Folding** (also only with `looks` on). An unnamed group as like a named
/// person as two unnamed groups must be to merge (`fold`), and clearly more
/// like them than anyone else named (`foldMargin`), is that person, and
/// joins them. The average faces have to point to the same person as the
/// looks do. Never one photographed with them, and never one with a face
/// the person said isn't them.
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
    /// A face this like a person (or, with looks on, one of their looks)
    /// joins them. Also how alike faces must be to start a look together.
    static let join: Float = 0.50
    /// A small face is a blurrier one, so it has to be closer to join.
    static let joinSmall: Float = 0.56
    /// Questions use the average face only, never looks.
    static let suggest: Float = 0.40
    /// Two unnamed groups this alike are one person, and so are two looks of
    /// one person.
    static let merge: Float = 0.62
    /// With looks on, an unnamed group this like a named person (their
    /// average or one of their looks) is that person...
    static let fold: Float = 0.62
    /// ...if it's at least this much more like them than like anyone else
    /// named, so two brothers who look alike are left for the person to
    /// tell apart.
    static let foldMargin: Float = 0.08
    static let minScore: Float = 0.85
    /// Faces at least this big (in the 1,280-pixel render) can start a person.
    static let seedPixels = 40
    static let minPixels = 24
    static let newPersonFaces = 4
    static let newPersonFiles = 3
    static let maxSuggestions = 60
    /// At most this many passes in a row run again at once because the last
    /// one merged someone.
    static let maxFollowUps = 10
    /// SFace's numbers per face.
    static let dimensions = 128

    private let app: Application
    private let seal: FaceSeal
    private let startDelay: Duration
    private let interval: Duration
    private let settle: Duration
    /// Several looks per person, and unnamed groups folded into named
    /// people. Off unless the server is started with it.
    private let looks: Bool
    /// Passes in a row that ran again straight away because the last one
    /// merged someone. See `refresh`.
    private var followUps: [UUID: Int] = [:]
    private var seen: [UUID: Int] = [:]
    private var lastPass: [UUID: ContinuousClock.Instant] = [:]
    private var dirty: Set<UUID> = []
    private var task: Task<Void, Never>?
    /// Makes everyone's circle after each pass. See `FaceCropWarmer`.
    private let warmer: FaceCropWarmer

    /// The smoke tests shorten all three.
    init(
        app: Application, seal: FaceSeal, startDelay: Duration = .seconds(45),
        interval: Duration = .seconds(60), settle: Duration = .seconds(900),
        looks: Bool = false
    ) {
        self.app = app
        self.seal = seal
        self.startDelay = startDelay
        self.interval = interval
        self.settle = settle
        self.looks = looks
        self.warmer = FaceCropWarmer(app: app)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await warmer.stop()
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
                    SELECT u.id, (SELECT count(*)::int FROM nas_faces f
                                  WHERE f.user_id = u.id AND f.embedding IS NOT NULL) AS faces
                    FROM users u
                    WHERE u.nas_analysis <> 'off' AND u.people_enabled AND u.deleted_at IS NULL
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
                        // Whoever the pass placed, and whatever the person
                        // just decided, gets their circle before it's asked
                        // for. The first pass after a start makes any that
                        // a new crop version or cover rule left unmade.
                        await warmer.warm(row.id)
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
        /// People the person took off the page. Never folded into anyone,
        /// and no one is folded into them.
        var hidden: Set<UUID> = []
    }

    /// What one pass decided, before any of it is written.
    struct Plan: Sendable {
        var newAuto: [(face: Int, person: UUID, similarity: Float)] = []
        var created: [(id: UUID, faces: [Int])] = []
        /// Unnamed people merged into one another and, with looks on,
        /// unnamed people folded into named ones, in the order they happened:
        /// a `from` may be an earlier merge's `into`.
        var merges: [(from: UUID, into: UUID)] = []
        var suggestions: [(face: Int, person: UUID, similarity: Float)] = []
        /// The merges into a named person, with how alike the two were.
        /// Each is in `merges` too. Empty with looks off.
        var folds: [(from: UUID, into: UUID, similarity: Float)] = []
        /// Each person's looks, for a report. Empty with looks off.
        var looks: [UUID: LookCount] = [:]
    }

    /// How many looks one person has, for a report.
    struct LookCount: Sendable, Equatable {
        /// Looks with enough faces to count, the main one among them.
        let looks: Int
        /// Of those, how many were set aside as too like someone else.
        let setAside: Int
        /// Of those, how many a face may join by: none when only the main
        /// look is left, since that's the person's average all but exactly.
        var used: Int { looks - setAside > 1 ? looks - setAside : 0 }
    }

    struct Membership: Decodable, Sendable {
        let sha256: String
        let ordinal: Int
        let personID: UUID
        let state: String
    }

    func refresh(userID: UUID) async throws {
        let started = ContinuousClock.now
        let (library, orphans) = try await load(userID)

        // Off this actor, so a person naming someone never waits on a pass.
        let input = library
        let looks = self.looks
        let plan = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.plan(input, looks: looks))
            }
        }

        try await write(userID: userID, library: library, plan: plan, orphans: orphans)
        // Looks are fixed for a pass, so one fold can make the next possible
        // only on the pass after. Run again soon until a pass merges no one.
        // Each merge takes an unnamed person away for good, so this ends; the
        // cap is there in case it somehow doesn't, and then the ordinary
        // schedule carries on.
        if looks, !plan.merges.isEmpty, followUps[userID, default: 0] < Self.maxFollowUps {
            followUps[userID, default: 0] += 1
            dirty.insert(userID)
        } else {
            followUps[userID] = nil
        }
        let elapsed = ContinuousClock.now - started
        let ms = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        if !plan.newAuto.isEmpty || !plan.created.isEmpty || !plan.merges.isEmpty {
            app.logger.info("people: \(plan.newAuto.count) faces placed, \(plan.created.count) new people, \(plan.merges.count) merged, \(plan.suggestions.count) questions, \(library.faces.count) faces in \(ms) ms")
        }
    }

    /// One library as it stands: its faces, opened, and who each one is.
    /// Reads only.
    func load(_ userID: UUID) async throws -> (library: Library, orphans: [Membership]) {
        var library = try await loadFaces(userID)
        let byKey = Dictionary(uniqueKeysWithValues: library.faces.indices.map { (library.faces[$0].key, $0) })

        struct PersonRow: Decodable { let id: UUID; let named: Bool; let hidden: Bool }
        let personRows = try await app.sql.raw("""
            SELECT id, name IS NOT NULL AS named, hidden FROM people WHERE user_id = \(bind: userID)
            """).all(decoding: PersonRow.self)
        let memberships = try await app.sql.raw("""
            SELECT sha256, ordinal::int AS ordinal, person_id AS "personID", state
            FROM person_faces WHERE user_id = \(bind: userID)
            """).all(decoding: Membership.self)

        let sorted = personRows.sorted { $0.id.uuidString < $1.id.uuidString }
        library.people = sorted.map(\.id)
        library.named = Set(sorted.filter(\.named).map(\.id))
        library.hidden = Set(sorted.filter(\.hidden).map(\.id))
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
        return (library, orphans)
    }

    /// How alike two people are, for `analysis people-matches`: cosine
    /// between their average faces (or, with looks on, the greater of that
    /// and the first's average against any look of the second's a face may
    /// join by), and how many of the first's faces the owner said aren't the
    /// second.
    struct Likeness: Sendable {
        let person: UUID
        let similarity: Float
        let rejected: Int
        /// The two share a photo frame, so they can't be one person.
        let together: Bool
    }

    /// For each person, everyone named, closest first. Pure, reads and
    /// writes nothing; a report of what folding unnamed people into named
    /// ones would do, before anything does it. With `looks` on, the likeness
    /// is the one a fold would use: see the fold step in `plan`.
    static func likenesses(_ library: Library, looks useLooks: Bool = false) -> [UUID: [Likeness]] {
        guard library.vectors.count == library.faces.count * dimensions else { return [:] }
        var centroids = Centroids()
        for id in library.people { _ = centroids.append(id: id, named: library.named.contains(id)) }
        var out: [UUID: [Likeness]] = [:]
        library.vectors.withUnsafeBufferPointer { buffer in
            let vectors = buffer.baseAddress!
            for m in library.members { centroids.add(m.face, to: m.person, faces: library.faces, vectors: vectors) }
            var looks = Looks(people: 0)
            if useLooks {
                looks = Self.looks(of: centroids, people: centroids.count, faces: library.faces, vectors: vectors)
            }
            let named = (0..<centroids.count).filter { centroids.named[$0] && centroids.counts[$0] > 0 }
            for g in 0..<centroids.count where centroids.counts[g] > 0 {
                guard let id = centroids.ids[g] else { continue }
                var list: [Likeness] = []
                for n in named where n != g {
                    guard let other = centroids.ids[n] else { continue }
                    let rejected = centroids.members[g].filter { library.rejected[$0]?.contains(other) == true }.count
                    var s = centroids.similarity(g, n)
                    if useLooks {
                        for l in looks.usable[n] { s = max(s, looks.centroids.similarity(l, to: centroids, g)) }
                    }
                    list.append(Likeness(
                        person: other, similarity: s, rejected: rejected,
                        together: !centroids.frames[g].isDisjoint(with: centroids.frames[n])
                    ))
                }
                out[id] = list.sorted { $0.similarity > $1.similarity }
            }
        }
        return out
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

        /// Cosine between one of these and one of another set's, such as a
        /// look and a person.
        func similarity(_ g: Int, to other: Centroids, _ h: Int) -> Float {
            guard counts[g] > 0, other.counts[h] > 0 else { return -1 }
            let stride = PeopleClusterer.dimensions * 4
            return sums.withUnsafeBufferPointer { sum in
                other.sums.withUnsafeBufferPointer { otherSum in
                    PeopleClusterer.dot(UnsafeRawPointer(sum.baseAddress!) + g * stride,
                                        UnsafeRawPointer(otherSum.baseAddress!) + h * stride)
                }
            } * inverseNorms[g] * other.inverseNorms[h]
        }

        /// A copy of another set's centroid `h`, as a new one here.
        mutating func append(copyOf h: Int, from other: Centroids) -> Int {
            let d = PeopleClusterer.dimensions
            sums.append(contentsOf: other.sums[(h * d)..<((h + 1) * d)])
            inverseNorms.append(other.inverseNorms[h])
            counts.append(other.counts[h])
            frames.append(other.frames[h])
            files.append(other.files[h])
            members.append(other.members[h])
            ids.append(other.ids[h])
            named.append(other.named[h])
            return count - 1
        }
    }

    /// Each person's looks for one pass, worked out from their own faces and
    /// fixed until the next. Only looks with enough faces to have been an
    /// unnamed person of their own are kept.
    struct Looks {
        /// The kept looks, side by side.
        var centroids = Centroids()
        /// Whose each look is, as an index into the pass's people.
        var person: [Int] = []
        /// Each look set aside as too like someone else, and never used.
        var setAside: [Bool] = []
        /// Per person, their look with the most faces.
        var main: [Int?]
        /// Per person, the looks a face may join them by: the main one and
        /// any not set aside. Empty when only the main look is left, since
        /// that adds nothing to the average but cost.
        var usable: [[Int]]

        init(people: Int) {
            main = Array(repeating: nil, count: people)
            usable = Array(repeating: [], count: people)
        }

        func counts(ids: [UUID?]) -> [UUID: LookCount] {
            var looks: [Int: Int] = [:], aside: [Int: Int] = [:]
            for l in person.indices {
                looks[person[l], default: 0] += 1
                if setAside[l] { aside[person[l], default: 0] += 1 }
            }
            var out: [UUID: LookCount] = [:]
            for (p, n) in looks {
                if let id = ids[p] { out[id] = LookCount(looks: n, setAside: aside[p] ?? 0) }
            }
            return out
        }
    }

    /// Sorts each person's faces into looks: the groups they'd fall into if
    /// they were strangers, by the same rules that group strangers. Then sets
    /// aside any look, other than the main one, that is at least as like
    /// someone else (anyone named, or anyone in a photo with them) as it is
    /// like the main one: a few of a sister's faces that crept in must not
    /// become a way for all of hers to follow. When in
    /// doubt a look falls silent and the person's average is all that's used.
    ///
    /// `centroids` are the pass's people with their members added and
    /// nothing else yet.
    static func looks(of centroids: Centroids, people: Int, faces: [Face], vectors: UnsafePointer<Float>) -> Looks {
        let raw = UnsafeRawPointer(vectors)
        var looks = Looks(people: people)
        for p in 0..<people where centroids.counts[p] >= newPersonFaces {
            // Members come in database order, which isn't fixed.
            var work = Centroids()
            for f in centroids.members[p].sorted() {
                var best = -1
                var bestSimilarity: Float = 0
                for l in 0..<work.count {
                    let s = work.similarity(l, to: raw + f * dimensions * 4)
                    if s >= join, best < 0 || s > bestSimilarity {
                        best = l
                        bestSimilarity = s
                    }
                }
                if best < 0 { best = work.append(id: nil, named: false) }
                work.add(f, to: best, faces: faces, vectors: vectors)
            }
            // Looks this alike are one, as unnamed people are.
            var gone = Set<Int>()
            outer: for a in 0..<work.count where !gone.contains(a) {
                for b in (a + 1)..<work.count where !gone.contains(b) {
                    guard work.frames[a].isDisjoint(with: work.frames[b]),
                          work.similarity(a, b) >= merge
                    else { continue }
                    let (into, from) = work.counts[a] >= work.counts[b] ? (a, b) : (b, a)
                    gone.insert(from)
                    work.absorb(from, into: into)
                    if from == a { continue outer }
                }
            }
            var mainLook: Int?
            for l in 0..<work.count
            where !gone.contains(l) && work.counts[l] >= newPersonFaces && work.files[l].count >= newPersonFiles {
                let kept = looks.centroids.append(copyOf: l, from: work)
                looks.person.append(p)
                if mainLook.map({ work.counts[l] > looks.centroids.counts[$0] }) ?? true { mainLook = kept }
            }
            looks.main[p] = mainLook
        }

        // Set aside what's as like someone else as like its own main look.
        let all = looks.centroids.count
        looks.setAside = Array(repeating: false, count: all)
        for l in 0..<all {
            let p = looks.person[l]
            guard let main = looks.main[p], main != l else { continue }
            let own = looks.centroids.similarity(l, main)
            // Someone else for sure: anyone the owner named, and anyone in a
            // photo with this person. An unnamed group never seen with them
            // may be them, another look not yet folded in, and counting it
            // would set aside the very look it's about to join.
            func isSomeoneElse(_ q: Int) -> Bool {
                q != p && (centroids.named[q] || !centroids.frames[q].isDisjoint(with: centroids.frames[p]))
            }
            var aside = false
            for q in 0..<people where isSomeoneElse(q) && looks.centroids.similarity(l, to: centroids, q) >= own {
                aside = true
                break
            }
            if !aside {
                for m in 0..<all where isSomeoneElse(looks.person[m]) && looks.centroids.similarity(l, m) >= own {
                    aside = true
                    break
                }
            }
            looks.setAside[l] = aside
        }
        for l in 0..<all where !looks.setAside[l] { looks.usable[looks.person[l]].append(l) }
        for p in 0..<people where looks.usable[p].count < 2 { looks.usable[p] = [] }
        return looks
    }

    /// Each person's looks as a pass would find them, for a report. Pure,
    /// reads and writes nothing.
    static func looks(_ library: Library) -> [UUID: LookCount] {
        guard !library.faces.isEmpty, library.vectors.count == library.faces.count * dimensions else { return [:] }
        var centroids = Centroids()
        for id in library.people { _ = centroids.append(id: id, named: library.named.contains(id)) }
        return library.vectors.withUnsafeBufferPointer { buffer in
            let vectors = buffer.baseAddress!
            for m in library.members { centroids.add(m.face, to: m.person, faces: library.faces, vectors: vectors) }
            return looks(of: centroids, people: centroids.count, faces: library.faces, vectors: vectors)
                .counts(ids: centroids.ids)
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
    /// With `looks` off it is exactly the grouping from before looks.
    static func plan(_ library: Library, looks useLooks: Bool = false) -> Plan {
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

            // Everyone's looks, from their faces so far; fixed for the pass.
            var looks = Looks(people: 0)
            if useLooks {
                looks = Self.looks(of: centroids, people: known, faces: faces, vectors: vectors)
                plan.looks = looks.counts(ids: centroids.ids)
            }

            // Faces no one has yet, each to the closest person it's close
            // enough to: their average or, with looks on, whichever look is
            // closer. The first of equals wins.
            var waiting: [Int] = []
            for f in faces.indices where !placed[f] {
                let needed = faces[f].pixels >= seedPixels ? join : joinSmall
                let excluded = library.rejected[f] ?? []
                var best: (g: Int, similarity: Float)?
                for g in 0..<known {
                    var s = centroids.similarity(g, to: vector(f))
                    if useLooks {
                        for l in looks.usable[g] { s = max(s, looks.centroids.similarity(l, to: vector(f))) }
                    }
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

            // With looks on, an unnamed person clearly like one named person
            // is them. The named person has to be the closest of everyone
            // named, by `foldMargin`, so a lookalike of someone they can't be
            // isn't handed to the next closest. And never someone they were
            // photographed with, or one with a face the person said isn't
            // them, or anyone hidden: then it's left for the person to say.
            if useLooks {
                let named = (0..<known).filter { centroids.named[$0] && centroids.counts[$0] > 0 }
                for u in people where !centroids.named[u] && !gone.contains(u) && centroids.counts[u] > 0 {
                    guard !named.isEmpty, let idU = centroids.ids[u], !library.hidden.contains(idU) else { continue }
                    var best: (g: Int, similarity: Float)?
                    var second: Float = -1
                    // Who they're most like by average alone. A look is a
                    // tighter thing than an average and scores higher, so
                    // one look can put a group over the bar for someone the
                    // averages don't point to. Then the two disagree, and
                    // it's left for the person to say.
                    var byAverage: (g: Int, similarity: Float)?
                    for n in named {
                        var s = centroids.similarity(u, n)
                        if s > (byAverage?.similarity ?? -1) { byAverage = (n, s) }
                        for l in looks.usable[n] { s = max(s, looks.centroids.similarity(l, to: centroids, u)) }
                        if let b = best, s <= b.similarity {
                            second = max(second, s)
                        } else {
                            if let b = best { second = b.similarity }
                            best = (n, s)
                        }
                    }
                    guard let best, best.similarity >= fold, best.similarity - second >= foldMargin,
                          byAverage?.g == best.g,
                          let idN = centroids.ids[best.g], !library.hidden.contains(idN),
                          centroids.frames[u].isDisjoint(with: centroids.frames[best.g]),
                          !centroids.members[u].contains(where: { library.rejected[$0]?.contains(idN) == true })
                    else { continue }
                    plan.merges.append((from: idU, into: idN))
                    plan.folds.append((from: idU, into: idN, similarity: best.similarity))
                    gone.insert(u)
                    centroids.absorb(u, into: best.g)
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
            WHERE f.user_id = \(bind: userID) AND n.status = 'done' AND f.embedding IS NOT NULL
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
                    // Only someone still unnamed is merged away. The person
                    // may have named them while the pass ran, and then
                    // their faces must not be copied to anyone; the lock
                    // keeps a naming from landing in between.
                    struct Unnamed: Decodable { let id: UUID }
                    guard try await sql.raw("""
                        SELECT id FROM people
                        WHERE id = \(bind: merge.from) AND user_id = \(bind: userID) AND name IS NULL
                        FOR UPDATE
                        """).first(decoding: Unnamed.self) != nil
                    else { continue }
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
