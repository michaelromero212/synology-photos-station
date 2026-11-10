import FrameStationAPI
import Foundation
import SQLKit

// MARK: - What an event album holds
//
// A birthday party is an afternoon, not the day it fell on. An album of the
// whole day held the morning at the pool before it and the screenshots from
// that evening, two photos "not associated with what the theme of the album
// is at all" (his word, 2026-11-10). So an event's album is the stretch of
// its day the event was: the stretches whose photos show it, and those beside
// them at the same place, but not a morning somewhere else.
//
// Worked out from the person's own observations, the same ones that found the
// event, on every visit. Keys stay whole days (`CuratedAlbums` matches on
// them), and what's left out is left out by the query that reads the day.

/// The parts of event days that aren't the event, and the photos that show
/// it.
struct EventScope: Sendable {
    /// Every placement (`space_assets.id`) on an event day that isn't part
    /// of the event: another stretch of the day. A screenshot taken during
    /// the party stays with it, as it always did, and is never its cover or
    /// a highlight.
    var outside: Set<UUID> = []
    /// The event's tag, by day.
    var tags: [String: String] = [:]
    /// By day, the files inside the event whose photos show it: the cake,
    /// the field, the stage.
    var showing: [String: Set<String>] = [:]

    var isEmpty: Bool { outside.isEmpty && showing.isEmpty }

    /// Leaves what isn't part of an event out of a query over
    /// `space_assets sa`.
    var filter: SQLQueryString {
        outside.isEmpty ? "" : "AND NOT (sa.id = ANY(\(bind: Array(outside))::uuid[]))"
    }

    // MARK: Bars

    /// A pause this long between photos starts another stretch of the day.
    static let pause: Double = 30 * 60
    /// A stretch beside the event's, at the same place, is part of it across
    /// a pause this long: the arrival an hour before the cake. Where there's
    /// no telling where either was, the time alone decides.
    static let reach: Double = 90 * 60
    /// Farther apart than this, two stretches were in two places.
    static let samePlace: Double = 1_000

    /// One photo of an event day.
    struct Row: Decodable, Sendable {
        /// The placement, `space_assets.id`.
        let id: UUID
        let sha256: String
        let day: String
        /// Seconds, on the photo's own wall clock.
        let at: Double
        let lat: Double?
        let lon: Double?
        /// Whether its photo shows the day's event.
        let shows: Bool
        /// A screenshot or a document.
        let utility: Bool
        /// The day's event.
        let tag: String
    }

    /// The event in each day: the stretches that show it, grown to the
    /// stretches beside them at the same place. A day where nothing shows it
    /// is left whole, as it was.
    static func plan(_ rows: [Row]) -> EventScope {
        var scope = EventScope()
        for (day, photos) in Dictionary(grouping: rows, by: \.day) {
            let ordered = photos.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
            var stretches: [[Row]] = []
            for row in ordered {
                if let last = stretches.last?.last, row.at - last.at <= pause {
                    stretches[stretches.count - 1].append(row)
                } else {
                    stretches.append([row])
                }
            }
            var kept = stretches.map { $0.contains { $0.shows && !$0.utility } }
            guard kept.contains(true) else { continue }
            var grew = true
            while grew {
                grew = false
                for index in stretches.indices where !kept[index] {
                    let besides = [index - 1, index + 1].filter { stretches.indices.contains($0) && kept[$0] }
                    if besides.contains(where: { joins(stretches[index], stretches[$0]) }) {
                        kept[index] = true
                        grew = true
                    }
                }
            }
            scope.tags[day] = ordered.first?.tag
            for (index, stretch) in stretches.enumerated() {
                for row in stretch {
                    if !kept[index] {
                        scope.outside.insert(row.id)
                    } else if row.shows, !row.utility {
                        scope.showing[day, default: []].insert(row.sha256)
                    }
                }
            }
        }
        return scope
    }

    /// Whether a stretch beside the event's was part of it: close enough in
    /// time, and in the same place where both say where they were.
    static func joins(_ stretch: [Row], _ event: [Row]) -> Bool {
        guard let first = stretch.first, let last = stretch.last,
              let start = event.first, let end = event.last else { return false }
        let gap = last.at < start.at ? start.at - last.at : first.at - end.at
        guard gap <= reach else { return false }
        guard let here = middle(of: stretch), let there = middle(of: event) else { return true }
        return meters(here, there) <= samePlace
    }

    /// Where a stretch was: the middle of its photos' places, which a stray
    /// fix can't move far.
    static func middle(of rows: [Row]) -> (lat: Double, lon: Double)? {
        let places = rows.compactMap { row in row.lat.flatMap { lat in row.lon.map { (lat, $0) } } }
        guard !places.isEmpty else { return nil }
        let lats = places.map(\.0).sorted()
        let lons = places.map(\.1).sorted()
        return (lats[lats.count / 2], lons[lons.count / 2])
    }

    static func meters(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.lat - a.lat) * radians
        let dLon = (b.lon - a.lon) * radians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * radians) * cos(b.lat * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }
}

extension CollectionsController {
    /// What of each event day was the event, for the person's own library.
    /// Not a day the person named: their name is for the whole day.
    static func eventScope(
        spaceID: UUID, userID: UUID, source: ObservationSource,
        events: [String: CurationVocabulary.Event], named: [String: String],
        on sql: any SQLDatabase
    ) async throws -> EventScope {
        let days = events.keys.filter { named[$0] == nil }.sorted()
        guard !days.isEmpty else { return EventScope() }
        let tags = days.compactMap { events[$0]?.tag }
        // Every row of each day, the halves of Live Photos and stacked RAWs
        // too, so what's left out is left out whole. Read a day at a time off
        // the capture-time index, not by formatting every photo's date: a
        // library holds a few hundred event days and tens of thousands of
        // others. A photo with no capture time of its own stays where it was.
        let rows = try await sql.raw("""
            SELECT sa.id, a.sha256, w.day, w.tag,
                   extract(epoch FROM a.local_captured_at)::float8 AS at,
                   a.lat, a.lon,
                   COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false) AS utility,
                   COALESCE(w.tag = ANY(o.tags), false) AS shows
            FROM unnest(\(bind: days)::text[], \(bind: tags)::text[]) AS w(day, tag)
            JOIN assets a ON a.local_captured_at >= w.day::timestamp
                         AND a.local_captured_at < w.day::timestamp + interval '1 day'
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                AND sa.deleted_at IS NULL
            LEFT JOIN \(unsafeRaw: source.table) o
                   ON o.user_id = \(bind: userID) AND o.sha256 = a.sha256
            """).all(decoding: EventScope.Row.self)
        return EventScope.plan(rows)
    }
}
