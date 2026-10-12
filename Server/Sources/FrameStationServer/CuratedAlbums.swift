import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// The trips and occasions a person has been shown, kept as the rules improve.
///
/// The Albums page works its trips and occasions out afresh on every visit,
/// from rules that keep getting better: better place names, holidays that have
/// to look like themselves, events the phone has learned to see. Left at that,
/// each improvement could retitle, split or quietly drop an album someone had
/// come to know. Apple's Photos keeps its memories and trips across iOS
/// updates, and this does the same:
///
/// - The first time an album is shown, it's saved under a stable identity.
/// - While the rules still find it, its name and dates follow theirs: a better
///   name is the point of an improvement. A small shift in dates is the same
///   album, matched by the days it shares.
/// - When the rules no longer find it, it stays as last shown, with its photos
///   counted afresh. It goes only when none of its photos are left, or when its
///   days have become part of a trip, which still shows them. While its photos
///   are all in Recently Deleted it waits, and putting them back brings it back.
/// - Albums from a feature the person has since turned off (holidays, or what
///   their devices saw) wait hidden until it's back on. A day the person named
///   goes when they take the name back.
/// - A holiday shown on its date alone, before the person's devices looked at
///   the day, is provisional: their analysis can still find it wasn't, and
///   then it goes. Once their analysis has confirmed it, it's kept like any
///   album, and a later reading can't take it away.
///
/// Saved: trips, and occasions that are something, such as a holiday, a name
/// the person gave a day, or an event. Not the "Every year on August 14"
/// prompts, which ask for a name and are offered one year at a time, and which
/// never take a kept album's place.
///
/// Per person and per library, like the page.
struct CuratedAlbums {
    let spaceID: UUID
    let userID: UUID
    let sql: any SQLDatabase
    let logger: Logger

    struct Saved: Decodable {
        let id: UUID
        let kind: String
        let key: String
        let title: String
        let subtitle: String?
        let occasion: String?
        let isEvent: Bool
        let isHoliday: Bool
        let isNamed: Bool
        let recursAnnually: Bool
        let provisional: Bool
        let hidden: Bool

        var album: Album {
            Album(
                kind: kind, key: key, title: title, subtitle: subtitle, occasion: occasion,
                isEvent: isEvent, isHoliday: isHoliday, isNamed: isNamed,
                recursAnnually: recursAnnually, provisional: provisional
            )
        }
    }

    /// An album as the rules found it, as it's saved.
    struct Album: Equatable {
        let kind: String
        let key: String
        let title: String
        let subtitle: String?
        let occasion: String?
        let isEvent: Bool
        let isHoliday: Bool
        let isNamed: Bool
        let recursAnnually: Bool
        let provisional: Bool

        init(
            kind: String, key: String, title: String, subtitle: String?, occasion: String? = nil,
            isEvent: Bool = false, isHoliday: Bool = false, isNamed: Bool = false,
            recursAnnually: Bool = false, provisional: Bool = false
        ) {
            self.kind = kind
            self.key = key
            self.title = title
            // Empty is saved as none, which an array bind can't carry.
            self.subtitle = subtitle?.isEmpty == true ? nil : subtitle
            self.occasion = occasion?.isEmpty == true ? nil : occasion
            self.isEvent = isEvent
            self.isHoliday = isHoliday
            self.isNamed = isNamed
            self.recursAnnually = recursAnnually
            self.provisional = provisional
        }
    }

    /// What decides a kept occasion's fate besides the rules: the person's own
    /// names, settings and analysis.
    struct Standing {
        /// The names the person gave days, by day.
        var named: [String: String] = [:]
        var showEvents = true
        var showHolidays = true
        /// Holiday days their devices haven't looked at yet.
        var unseen: Set<String> = []
        /// Holiday days their devices looked at and found weren't.
        var unlike: Set<String> = []
    }

    /// Nil when they couldn't be read. The page then shows what the rules
    /// found and writes nothing: matched against nothing, every refined album
    /// would be saved a second time.
    func load() async -> [Saved]? {
        do {
            return try await sql.raw("""
                SELECT id, kind, key, title, subtitle, occasion, is_event AS "isEvent",
                       is_holiday AS "isHoliday", is_named AS "isNamed",
                       recurs_annually AS "recursAnnually", provisional, hidden
                FROM curated_albums
                WHERE space_id = \(bind: spaceID) AND user_id = \(bind: userID)
                """).all(decoding: Saved.self)
        } catch {
            logger.error("curated albums: couldn't read kept albums: \(error)")
            return nil
        }
    }

    // MARK: - Trips

    /// The trips to show: today's, each kept as the album it was before, and
    /// those the rules no longer find, as they were. Newest first.
    func keep(
        trips found: [CollectionSummary], saved all: [Saved]?, limit: Int, seed: String
    ) async -> [CollectionSummary] {
        guard let all else { return found }
        let kind = CollectionKind.trip.rawValue
        let saved = all.filter { $0.kind == kind }
        let pairs = Self.pair(found.map(\.key), with: saved)
        var changes = Changes()

        var shown: [CollectionSummary] = []
        for (index, trip) in found.enumerated() {
            let album = Album(kind: kind, key: trip.key, title: trip.title, subtitle: trip.subtitle)
            if let match = pairs[index] {
                guard !match.hidden else { continue }
                changes.update(match, to: album)
            } else {
                changes.inserts.append(album)
            }
            shown.append(trip)
        }

        // What the rules no longer find. A trip whose days today's trips now
        // cover was merged into one of them, which still shows its photos.
        let paired = Set(pairs.values.map(\.id))
        let unpaired = saved.filter { !paired.contains($0.id) && !$0.hidden }
        var waiting: [Saved] = []
        if !unpaired.isEmpty {
            let covered = Set(shown.flatMap { CollectionsController.days(inKey: $0.key) })
            for row in unpaired {
                if covered.isSuperset(of: CollectionsController.days(inKey: row.key)) {
                    changes.deletes.append(row.id)
                } else {
                    waiting.append(row)
                }
            }
        }

        let restored = await restore(Self.within(limit, of: shown.map(\.key), waiting), seed: seed)
        changes.deletes += restored.gone
        await write(changes)
        shown += restored.kept.map { row, photos in
            CollectionSummary(
                kind: .trip, key: row.key, title: row.title, subtitle: row.subtitle,
                count: photos.count, coverAssetIDs: photos.coverAssetIDs
            )
        }
        return Array(shown.sorted { $0.key > $1.key }.prefix(limit))
    }

    // MARK: - Occasions

    /// The occasions to show, kept the same way as trips. `claimed` is every
    /// day inside a trip: an occasion those days were has become part of it.
    func keep(
        occasions found: [CollectionsController.Occasion], saved all: [Saved]?, claimed: Set<String>,
        standing: Standing, limit: Int, seed: String
    ) async -> [CollectionsController.Occasion] {
        guard let all else { return found }
        let kind = CollectionKind.day.rawValue
        let saved = all.filter { $0.kind == kind }
        let pairs = Self.pair(found.map(\.summary.key), with: saved)
        var changes = Changes()

        var shown: [CollectionsController.Occasion] = []
        var waiting: [Saved] = []
        for (index, candidate) in found.enumerated() {
            let summary = candidate.summary
            let match = pairs[index]
            let album = Album(
                kind: kind, key: summary.key, title: summary.title, subtitle: summary.subtitle,
                occasion: candidate.occasion, isEvent: candidate.isEvent,
                isHoliday: candidate.isHoliday, isNamed: summary.isNamed,
                recursAnnually: summary.recursAnnually,
                // Once their analysis has confirmed it, it stays confirmed.
                provisional: candidate.isHoliday && (match?.provisional ?? true)
                    && CollectionsController.days(inKey: summary.key).contains(where: standing.unseen.contains)
            )
            guard let match else {
                if candidate.occasion != nil { changes.inserts.append(album) }
                shown.append(candidate)
                continue
            }
            guard !match.hidden else { continue }
            guard candidate.occasion == nil else {
                changes.update(match, to: album)
                shown.append(candidate)
                continue
            }
            // An "Every year on…" prompt where a kept album is. The album
            // stays, unless its feature is off or the person undid it.
            switch Self.fate(of: match, standing: standing) {
            case .shown:
                waiting.append(match)
            case .waits:
                shown.append(candidate)
            case .goes:
                changes.deletes.append(match.id)
                shown.append(candidate)
            }
        }

        let paired = Set(pairs.values.map(\.id))
        let unpaired = saved.filter { !paired.contains($0.id) && !$0.hidden }
        if !unpaired.isEmpty {
            let covered = claimed.union(shown.flatMap { CollectionsController.days(inKey: $0.summary.key) })
            for row in unpaired {
                if covered.isSuperset(of: CollectionsController.days(inKey: row.key)) {
                    changes.deletes.append(row.id)
                    continue
                }
                switch Self.fate(of: row, standing: standing) {
                case .shown: waiting.append(row)
                case .waits: continue
                case .goes: changes.deletes.append(row.id)
                }
            }
        }

        let restored = await restore(
            Self.within(limit, of: shown.map(\.summary.key), waiting), seed: seed
        )
        changes.deletes += restored.gone
        await write(changes)
        shown += restored.kept.map { row, photos in
            // A day the person renamed takes its new name.
            let name = CollectionsController.days(inKey: row.key).lazy.compactMap { standing.named[$0] }.first
            return CollectionsController.Occasion(
                summary: CollectionSummary(
                    kind: .day, key: row.key, title: name ?? row.title,
                    subtitle: Self.recounted(row.subtitle, photos: photos),
                    count: photos.count, coverAssetIDs: photos.coverAssetIDs, isNamed: name != nil,
                    recursAnnually: row.recursAnnually
                ),
                occasion: name ?? row.occasion, isEvent: row.isEvent, isHoliday: row.isHoliday
            )
        }
        return Array(shown.sorted { $0.summary.key > $1.summary.key }.prefix(limit))
    }

    /// What becomes of a kept occasion the rules no longer find.
    enum Fate: Equatable {
        case shown
        /// Until the feature that found it is back on.
        case waits
        case goes
    }

    static func fate(of row: Saved, standing: Standing) -> Fate {
        let days = CollectionsController.days(inKey: row.key)
        // The person's own name, which only they take back.
        if row.isNamed {
            return days.contains { standing.named[$0] != nil } ? .shown : .goes
        }
        // Shown on its date alone, and their own devices have since found it
        // wasn't that holiday. Their photos, not a change of rules.
        if row.isHoliday, row.provisional, days.contains(where: standing.unlike.contains) {
            return .goes
        }
        if (row.isEvent && !standing.showEvents) || (row.isHoliday && !standing.showHolidays) {
            return .waits
        }
        return .shown
    }

    // MARK: - Matching

    /// Pairs today's albums with saved ones: the same days, or failing that,
    /// the saved album sharing the most days with it, which is the same album
    /// with its dates refined. Each pairs once, the closest first, so a
    /// neighbor can't claim an album that's still found as it was, or one
    /// another of today's albums shares more days with.
    static func pair(_ keys: [String], with saved: [Saved]) -> [Int: Saved] {
        var pairs: [Int: Saved] = [:]
        var taken = Set<UUID>()
        let byKey = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, key) in keys.enumerated() {
            if let match = byKey[key], !taken.contains(match.id) {
                pairs[index] = match
                taken.insert(match.id)
            }
        }
        let open = saved.filter { !taken.contains($0.id) }
        guard !open.isEmpty, pairs.count < keys.count else { return pairs }

        struct Overlap {
            let index: Int
            let row: Saved
            let shared: Int
        }
        let openDays = open.map { Set(CollectionsController.days(inKey: $0.key)) }
        var overlaps: [Overlap] = []
        for (index, key) in keys.enumerated() where pairs[index] == nil {
            let days = CollectionsController.days(inKey: key)
            for (row, rowDays) in zip(open, openDays) {
                let shared = days.reduce(0) { $0 + (rowDays.contains($1) ? 1 : 0) }
                if shared > 0 { overlaps.append(Overlap(index: index, row: row, shared: shared)) }
            }
        }
        // Among equals, the earlier album, so the choice holds still.
        overlaps.sort { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            if a.row.key != b.row.key { return a.row.key < b.row.key }
            return a.index < b.index
        }
        for overlap in overlaps where pairs[overlap.index] == nil && !taken.contains(overlap.row.id) {
            pairs[overlap.index] = overlap.row
            taken.insert(overlap.row.id)
        }
        return pairs
    }

    /// The saved albums that would make the list's first `limit`, alongside
    /// the ones the rules found. Only those are worth counting photos for.
    static func within(_ limit: Int, of shown: [String], _ waiting: [Saved]) -> [Saved] {
        let cut = (shown + waiting.map(\.key)).sorted(by: >).prefix(limit)
        guard let last = cut.last else { return [] }
        return waiting.filter { $0.key >= last }
    }

    // MARK: - Photos

    /// A kept album's photos as they are today.
    struct Photos: Decodable {
        let id: UUID
        /// Leaving out those in Recently Deleted, as all of these do.
        let count: Int
        let videos: Int
        let coverAssetIDs: [UUID]
    }

    /// A kept occasion's subtitle, with its videos counted as they are today:
    /// the one part of it that can go out of date.
    static func recounted(_ subtitle: String?, photos: Photos) -> String? {
        var parts = subtitle.map { $0.components(separatedBy: " · ") } ?? []
        if let last = parts.last, last.hasSuffix(" video") || last.hasSuffix(" videos"),
           last.first?.isNumber == true {
            parts.removeLast()
        }
        if let videos = CollectionsController.videoNote(videos: photos.videos, of: photos.count) {
            parts.append(videos)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Each album's photos as they are today: how many, and the best covers.
    /// One whose photos are all in Recently Deleted waits for them; one with
    /// none left at all is gone.
    private func restore(
        _ rows: [Saved], seed: String
    ) async -> (kept: [(Saved, Photos)], gone: [UUID]) {
        guard !rows.isEmpty else { return ([], []) }
        // Each album as its days, so the library is read once, matched by day.
        let days = rows.flatMap { row in
            CollectionsController.days(inKey: row.key).map { (id: row.id, day: $0) }
        }
        let local = TimelineController.localTime
        let photos: [Photos]
        do {
            photos = try await sql.raw("""
                SELECT d.id,
                       count(*) FILTER (WHERE sa.deleted_at IS NULL)::int AS count,
                       count(*) FILTER (WHERE sa.deleted_at IS NULL AND a.media_type = 'video')::int
                           AS videos,
                       COALESCE((ARRAY_AGG(a.id ORDER BY \(unsafeRaw: CollectionsController.coverOrder(seed: seed)))
                                    FILTER (WHERE sa.deleted_at IS NULL))
                                [1:\(unsafeRaw: String(CollectionsController.coverDepth))], '{}')
                           AS "coverAssetIDs"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                JOIN unnest(\(bind: days.map(\.id))::uuid[], \(bind: days.map(\.day))::text[]) AS d(id, day)
                  ON d.day = to_char(\(unsafeRaw: local), 'YYYY-MM-DD')
                \(CollectionsController.observed(by: userID))
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.purged_at IS NULL
                  AND \(unsafeRaw: TimelineController.visible)
                GROUP BY d.id
                """).all(decoding: Photos.self)
        } catch {
            logger.error("curated albums: couldn't count kept albums: \(error)")
            return ([], [])
        }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var kept: [(Saved, Photos)] = []
        var gone: [UUID] = []
        for row in rows {
            guard let found = byID[row.id] else {
                gone.append(row.id)
                continue
            }
            if found.count > 0 { kept.append((row, found)) }
        }
        return (kept, gone)
    }

    // MARK: - Writing

    /// What one visit changes.
    struct Changes {
        var inserts: [Album] = []
        var updates: [(id: UUID, album: Album)] = []
        var deletes: [UUID] = []

        /// A kept album takes what the rules find now, where that's different.
        mutating func update(_ row: Saved, to album: Album) {
            if row.album != album { updates.append((row.id, album)) }
        }
    }

    /// A statement of each kind, however much a visit changed. Never at the
    /// page's expense: a failed write is logged, the page shows what it found,
    /// and the next visit tries again.
    private func write(_ changes: Changes) async {
        // Letting go first frees the dates an update may move onto.
        if !changes.deletes.isEmpty {
            await run("let go of albums", """
                DELETE FROM curated_albums
                WHERE id = ANY(\(bind: changes.deletes)::uuid[])
                  AND space_id = \(bind: spaceID) AND user_id = \(bind: userID)
                """)
        }
        if !changes.updates.isEmpty {
            let albums = changes.updates.map(\.album)
            await run("update albums", """
                UPDATE curated_albums AS c
                SET key = v.key, title = v.title, subtitle = NULLIF(v.subtitle, ''),
                    occasion = NULLIF(v.occasion, ''), is_event = v.is_event,
                    is_holiday = v.is_holiday, is_named = v.is_named,
                    recurs_annually = v.recurs_annually, provisional = v.provisional, updated_at = now()
                FROM unnest(\(bind: changes.updates.map(\.id))::uuid[], \(bind: albums.map(\.key))::text[],
                            \(bind: albums.map(\.title))::text[], \(bind: albums.map { $0.subtitle ?? "" })::text[],
                            \(bind: albums.map { $0.occasion ?? "" })::text[], \(bind: albums.map(\.isEvent))::bool[],
                            \(bind: albums.map(\.isHoliday))::bool[], \(bind: albums.map(\.isNamed))::bool[],
                            \(bind: albums.map(\.recursAnnually))::bool[], \(bind: albums.map(\.provisional))::bool[])
                     AS v(id, key, title, subtitle, occasion, is_event, is_holiday, is_named, recurs_annually,
                          provisional)
                WHERE c.id = v.id AND c.space_id = \(bind: spaceID) AND c.user_id = \(bind: userID)
                """)
        }
        if !changes.inserts.isEmpty {
            let albums = changes.inserts
            await run("save albums", """
                INSERT INTO curated_albums
                    (space_id, user_id, kind, key, title, subtitle, occasion, is_event, is_holiday,
                     is_named, recurs_annually, provisional)
                SELECT \(bind: spaceID), \(bind: userID), v.kind, v.key, v.title, NULLIF(v.subtitle, ''),
                       NULLIF(v.occasion, ''), v.is_event, v.is_holiday, v.is_named, v.recurs_annually,
                       v.provisional
                FROM unnest(\(bind: albums.map(\.kind))::text[], \(bind: albums.map(\.key))::text[],
                            \(bind: albums.map(\.title))::text[], \(bind: albums.map { $0.subtitle ?? "" })::text[],
                            \(bind: albums.map { $0.occasion ?? "" })::text[], \(bind: albums.map(\.isEvent))::bool[],
                            \(bind: albums.map(\.isHoliday))::bool[], \(bind: albums.map(\.isNamed))::bool[],
                            \(bind: albums.map(\.recursAnnually))::bool[], \(bind: albums.map(\.provisional))::bool[])
                     AS v(kind, key, title, subtitle, occasion, is_event, is_holiday, is_named, recurs_annually,
                          provisional)
                ON CONFLICT (space_id, user_id, kind, key) DO NOTHING
                """)
        }
    }

    private func run(_ what: String, _ query: SQLQueryString) async {
        do {
            try await sql.raw(query).run()
        } catch {
            logger.error("curated albums: couldn't \(what): \(error)")
        }
    }
}
