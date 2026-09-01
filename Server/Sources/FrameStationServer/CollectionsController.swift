import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension CollectionsResponse: @retroactive Content {}

/// The Albums page, assembled from what the library already knows.
///
/// Every collection here is arithmetic over columns filled in at import — dates,
/// coordinates, counts. No model, no ML runtime, nothing leaving the NAS. That
/// is not a limitation being worked around; it is why this can run on a J4125
/// and be correct the day a library is imported rather than after an overnight
/// job that may not finish.
///
/// The page is deliberately *not* a list of everything that could be computed.
/// Apple's Albums tab reaches twenty-five rows before your own albums, most of
/// them media types, and the result reads as a filing cabinet. So sections that
/// would be thin are dropped server-side rather than sent and hidden: the app
/// should not have to know the rule, and a section that never renders should
/// never have cost a query.
struct CollectionsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("spaces", ":spaceID", "collections", use: page)
        protected.get("spaces", ":spaceID", "collections", "items", use: items)
    }

    /// Below this a collection isn't worth a card. Three photos from one day is
    /// a coincidence, not an occasion.
    static let minimumItems = 4

    // MARK: - The page

    @Sendable
    func page(req: Request) async throws -> CollectionsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // The phone's date, not the server's. "On this day" means the day the
        // person is having, and a NAS in another timezone — or simply awake at
        // 1am — would otherwise answer for the wrong one.
        let today = req.query[String.self, at: "date"].flatMap(Self.parseDate) ?? Date()
        // Rotates the covers daily and holds them still in between, so a card
        // stays recognisable for as long as anyone is looking at it.
        let seed = Self.dayStamp(today)

        let onThisDay = try await onThisDayCollections(
            spaceID: spaceID, today: today, seed: seed, userID: device.userID, on: req.sql
        )
        let days = try await busyDays(
            spaceID: spaceID, seed: seed, userID: device.userID, on: req.sql
        )
        let deleted = try await recentlyDeleted(spaceID: spaceID, on: req.sql)

        return CollectionsResponse(
            // The most recent year first: "last year today" beats "eleven years
            // ago today" as the thing to open a page with.
            hero: onThisDay.first,
            trips: [],
            days: days,
            recentlyDeleted: deleted
        )
    }

    // MARK: - On this day

    private struct OnThisDayRow: Decodable {
        let year: Int
        let count: Int
        let coverAssetID: UUID?
    }

    /// The same calendar day, in every earlier year that has photos.
    ///
    /// Matched on `local_captured_at` — the photo's own wall clock — so a
    /// picture taken at 9pm in Rome belongs to that evening and not to the next
    /// morning UTC. Getting this wrong shows the wrong day once a year to
    /// anyone who has travelled, which is the whole audience.
    private func onThisDayCollections(
        spaceID: UUID, today: Date, seed: String, userID: UUID, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let parts = Self.utc.dateComponents([.year, .month, .day], from: today)
        guard let month = parts.month, let day = parts.day, let year = parts.year else {
            return []
        }

        let rows = try await sql.raw("""
            SELECT EXTRACT(YEAR FROM \(unsafeRaw: TimelineController.localTime))::int AS year,
                   count(*)::int AS count,
                   (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed)))) [1] AS "coverAssetID"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND EXTRACT(MONTH FROM \(unsafeRaw: TimelineController.localTime)) = \(bind: month)
              AND EXTRACT(DAY   FROM \(unsafeRaw: TimelineController.localTime)) = \(bind: day)
              AND EXTRACT(YEAR  FROM \(unsafeRaw: TimelineController.localTime)) < \(bind: year)
            GROUP BY year
            HAVING count(*) >= \(bind: Self.minimumItems)
            ORDER BY year DESC
            """).all(decoding: OnThisDayRow.self)

        return rows.map { row in
            let ago = year - row.year
            return CollectionSummary(
                kind: .onThisDay,
                key: String(row.year),
                title: ago == 1 ? "A year ago today" : "\(ago) years ago today",
                subtitle: Self.dayLabel(month: month, day: day, year: row.year)
                    + " · " + Self.photoCount(row.count),
                count: row.count,
                coverAssetID: row.coverAssetID
            )
        }
    }

    // MARK: - Days worth keeping

    /// Everything a day can say about itself, gathered in one pass.
    ///
    /// These are the raw facts the title is written from. Reading them costs
    /// nothing extra — the day is already being grouped and counted — and
    /// without them every occasion in the library is called "A busy Saturday".
    struct DayRow: Decodable {
        let day: String
        let count: Int
        let place: String?
        let placeCount: Int
        let videoCount: Int
        let firstHour: Int
        let lastHour: Int
        let peopleCount: Int
        let coverAssetID: UUID?
    }

    /// Days that stand out against *this* library's own baseline.
    ///
    /// A threshold in absolute photos would be wrong for everyone: forty
    /// pictures is a quiet afternoon to one person and a wedding to another. So
    /// the bar is a multiple of the library's own median day, which makes a
    /// birthday legible without knowing it is a birthday.
    ///
    /// The median is taken over days that *have* photos rather than over the
    /// calendar — empty days would drag it to zero and make every day
    /// exceptional.
    ///
    /// Deliberately fetches far more days than it returns. Consecutive busy days
    /// are one occasion rather than several, and a Saturday and Sunday that
    /// arrive as separate cards are a weekend the app failed to notice — so the
    /// grouping happens after the query and the limit applies to the *runs*.
    private func busyDays(
        spaceID: UUID, seed: String, userID: UUID, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let local = TimelineController.localTime
        let rows = try await sql.raw("""
            WITH per_day AS (
                SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                       count(*)::int AS count,
                       mode() WITHIN GROUP (ORDER BY a.place_name) AS place,
                       count(DISTINCT a.place_name)::int AS "placeCount",
                       count(*) FILTER (WHERE a.media_type = 'video')::int AS "videoCount",
                       min(EXTRACT(HOUR FROM \(unsafeRaw: local)))::int AS "firstHour",
                       max(EXTRACT(HOUR FROM \(unsafeRaw: local)))::int AS "lastHour",
                       count(DISTINCT COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id))::int
                           AS "peopleCount",
                       (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed)))) [1] AS cover
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                GROUP BY day
            ),
            baseline AS (
                SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY count) AS median FROM per_day
            )
            SELECT p.day, p.count, p.place, p."placeCount", p."videoCount",
                   p."firstHour", p."lastHour", p."peopleCount", p.cover AS "coverAssetID"
            FROM per_day p, baseline b
            WHERE p.count >= GREATEST(b.median * 3, \(bind: Self.minimumItems * 2))
            ORDER BY p.day DESC
            LIMIT 60
            """).all(decoding: DayRow.self)

        return Self.runs(from: rows).prefix(6).map { Self.describe($0) }
    }

    /// A stretch of consecutive busy days, treated as one occasion.
    struct Run {
        var days: [DayRow]

        var count: Int { days.reduce(0) { $0 + $1.count } }
        var videoCount: Int { days.reduce(0) { $0 + $1.videoCount } }
        var first: DayRow { days.last! }   // rows arrive newest-first
        var last: DayRow { days.first! }
        var span: Int { days.count }

        /// The place most of the run happened in, or nil when it moved about.
        ///
        /// Weighted by photographs rather than by days: an afternoon somewhere
        /// with sixty pictures says more about where you were than a morning
        /// somewhere else with five.
        var place: String? {
            var weights: [String: Int] = [:]
            for day in days {
                guard let place = day.place else { continue }
                weights[place, default: 0] += day.count
            }
            guard let best = weights.max(by: { $0.value < $1.value }) else { return nil }
            // Only claim a place if most of the run actually happened there.
            return best.value * 2 >= count ? best.key : nil
        }

        var peopleCount: Int { days.map(\.peopleCount).max() ?? 1 }
        var placeCount: Int { days.map(\.placeCount).max() ?? 0 }
    }

    /// Groups consecutive days into runs. Rows arrive newest-first.
    static func runs(from rows: [DayRow]) -> [Run] {
        var runs: [Run] = []
        for row in rows {
            if var current = runs.last,
               let previous = current.days.last.flatMap({ parseDate($0.day) }),
               let this = parseDate(row.day),
               utc.dateComponents([.day], from: this, to: previous).day == 1 {
                current.days.append(row)
                runs[runs.count - 1] = current
            } else {
                runs.append(Run(days: [row]))
            }
        }
        return runs
    }

    // MARK: - Naming an occasion

    /// Writes a title from what the media actually is.
    ///
    /// Every rule here has to be *true* before it fires, and they are tried
    /// most-specific first. That ordering is the whole design: a title picked
    /// from a bag of phrases reads as decoration and people spot the repetition
    /// anyway, where a title that is earned — three places, an evening, mostly
    /// video — tells you something you would otherwise have to open the
    /// collection to find out.
    ///
    /// The generic weekday remains as the last resort, because a day that is
    /// simply busy is a real thing and deserves an honest name rather than a
    /// stretched one.
    static func describe(_ run: Run) -> CollectionSummary {
        let place = run.place
        let title: String
        // Whether the title already names where this happened, so the subtitle
        // doesn't say it twice — and, for a run that visited several places,
        // doesn't contradict a title that just said so.
        var titleNamedPlace = place != nil

        if run.span > 1 {
            title = runTitle(run, place: place)
        } else if run.placeCount >= 3 {
            title = "\(spelled(run.placeCount).capitalized) places in one day"
            titleNamedPlace = true
        } else if run.videoCount * 2 > run.count {
            title = inPlace("\(timeOfDay(run.first)) of video", place)
        } else if run.peopleCount >= 3 {
            title = inPlace("Everyone's photographs", place)
        } else if run.first.lastHour - run.first.firstHour >= 9 {
            title = inPlace("All day", place)
        } else if let phrase = narrowWindow(run.first) {
            title = inPlace(phrase, place)
        } else {
            title = "A busy \(stampFormatter("EEEE").string(from: parseDate(run.first.day) ?? Date()))"
            titleNamedPlace = false
        }

        return CollectionSummary(
            kind: .day,
            key: run.days.map(\.day).reversed().joined(separator: ".."),
            title: title,
            subtitle: subtitle(run, place: titleNamedPlace ? nil : place),
            count: run.count,
            coverAssetID: run.days.compactMap(\.coverAssetID).first
        )
    }

    /// Names a stretch of days. A weekend is worth recognising by name; four
    /// days in a row is worth counting.
    private static func runTitle(_ run: Run, place: String?) -> String {
        let weekdays = run.days.compactMap { parseDate($0.day) }
            .map { utc.component(.weekday, from: $0) }   // 1 = Sunday, 7 = Saturday
        let isWeekendPair = run.span == 2 && weekdays.contains(1) && weekdays.contains(7)
        let touchesWeekend = weekdays.contains(1) || weekdays.contains(7)

        let phrase: String
        if isWeekendPair {
            phrase = "A weekend"
        } else if run.span == 3, touchesWeekend {
            phrase = "A long weekend"
        } else {
            phrase = "\(spelled(run.span).capitalized) days"
        }
        return inPlace(phrase, place)
    }

    /// "An evening in Culpeper" — and just "An evening" where there is no
    /// location to name, rather than a sentence with a hole in it.
    private static func inPlace(_ phrase: String, _ place: String?) -> String {
        guard let place else { return phrase }
        // The stored name is "Culpeper, Virginia"; a title wants the town.
        let town = place.split(separator: ",").first.map(String.init) ?? place
        return "\(phrase) in \(town)"
    }

    /// A day that happened inside one part of it.
    private static func narrowWindow(_ day: DayRow) -> String? {
        if day.lastHour < 11 { return "A morning" }
        if day.firstHour >= 17 { return "An evening" }
        if day.firstHour >= 12, day.lastHour < 18 { return "An afternoon" }
        return nil
    }

    private static func timeOfDay(_ day: DayRow) -> String {
        narrowWindow(day) ?? "A day"
    }

    /// Dates and counts go here, so the title never has to carry them.
    private static func subtitle(_ run: Run, place: String?) -> String {
        var parts: [String] = []
        if run.span == 1 {
            parts.append(longDay(run.first.day) ?? run.first.day)
        } else if let from = parseDate(run.first.day), let to = parseDate(run.last.day) {
            // "12–16 August 2026", collapsing the month when it doesn't change.
            let sameMonth = utc.component(.month, from: from) == utc.component(.month, from: to)
            let left = stampFormatter(sameMonth ? "d" : "d MMM").string(from: from)
            parts.append("\(left)–\(stampFormatter("d MMMM yyyy").string(from: to))")
        }
        // The caller passes nil when the title already named the place, so a
        // card never reads "An evening in Culpeper · Culpeper, Virginia" — nor
        // "Three places in one day · Asheville", which is worse, because it
        // contradicts the line above it.
        if let place { parts.append(place) }
        if run.videoCount > 0, run.videoCount * 2 <= run.count {
            parts.append(run.videoCount == 1 ? "1 video" : "\(run.videoCount) videos")
        }
        return parts.joined(separator: " · ")
    }

    /// Small numbers read better as words in a title.
    private static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine"]
        return n < words.count ? words[n] : String(n)
    }

    // MARK: - Recently deleted

    private struct DeletedRow: Decodable {
        let count: Int
        let coverAssetID: UUID?
    }

    /// Removals still sitting in `#recycle`, for a personal space only.
    ///
    /// Shared-space removals are recovered through File Station rather than
    /// here — see ARCHITECTURE.md. Offering a restore in a shared space would
    /// mean deciding who is allowed to undo whose deletion, and DSM already has
    /// an answer for that.
    ///
    /// **`recycled_path` is not proof the file is there.** The bin carries
    /// DSM's own name, deliberately, so File Station treats it as a recycle bin
    /// — which means DSM's scheduled emptying can reclaim the bytes underneath
    /// us. Rows whose file has gone are excluded rather than offered and then
    /// failing on tap, which is the one way this feature could actively lie.
    private func recentlyDeleted(
        spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        struct KindRow: Decodable { let kind: String }
        let space = try await sql.raw("""
            SELECT kind FROM spaces WHERE id = \(bind: spaceID)
            """).first(decoding: KindRow.self)
        guard space?.kind == "personal" else { return nil }

        struct Candidate: Decodable {
            let assetID: UUID
            let recycledPath: String?
        }
        let candidates = try await sql.raw("""
            SELECT sa.asset_id AS "assetID", sa.recycled_path AS "recycledPath"
            FROM space_assets sa
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NOT NULL
            ORDER BY sa.deleted_at DESC
            LIMIT 500
            """).all(decoding: Candidate.self)

        let present = candidates.filter { candidate in
            guard let path = candidate.recycledPath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        guard !present.isEmpty else { return nil }

        return CollectionSummary(
            kind: .recentlyDeleted,
            key: "all",
            title: "Recently Deleted",
            subtitle: nil,
            count: present.count,
            coverAssetID: nil
        )
    }

    // MARK: - Contents

    /// The photos in one collection, decoded from the key the summary carried.
    @Sendable
    func items(req: Request) async throws -> SearchResults {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        guard let rawKind = req.query[String.self, at: "kind"],
              let kind = CollectionKind(rawValue: rawKind),
              let key = req.query[String.self, at: "key"]
        else {
            throw Abort(.badRequest, reason: "Missing collection kind or key.")
        }

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let filter: SQLQueryString
        switch kind {
        case .onThisDay:
            guard let year = Int(key) else {
                throw Abort(.badRequest, reason: "On This Day needs a year.")
            }
            // The month and day come from the request rather than the key, for
            // the same reason the page does: it is the phone's today.
            let today = req.query[String.self, at: "date"].flatMap(Self.parseDate) ?? Date()
            let parts = Self.utc.dateComponents([.month, .day], from: today)
            filter = """
                AND EXTRACT(YEAR  FROM \(unsafeRaw: TimelineController.localTime)) = \(bind: year)
                AND EXTRACT(MONTH FROM \(unsafeRaw: TimelineController.localTime)) = \(bind: parts.month ?? 1)
                AND EXTRACT(DAY   FROM \(unsafeRaw: TimelineController.localTime)) = \(bind: parts.day ?? 1)
                """
        case .day:
            filter = """
                AND to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD') = \(bind: key)
                """
        case .trip:
            throw Abort(.notImplemented, reason: "Trips aren't built yet.")
        case .recentlyDeleted:
            throw Abort(.badRequest, reason: "Recently Deleted has its own endpoint.")
        }

        let rows = try await req.sql.raw("""
            SELECT sa.id,
                   sa.space_id   AS "spaceID",
                   a.id          AS "assetID",
                   \(unsafeRaw: TimelineController.localTime) AT TIME ZONE 'UTC' AS "capturedAt",
                   a.width, a.height, a.orientation,
                   a.media_type  AS "mediaType",
                   a.duration_ms AS "durationMs",
                   a.thumbhash   AS "thumbHash",
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite",
                   COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "uploadedBy",
                   (a.derived_at IS NOT NULL) AS "isDerived"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              \(filter)
            ORDER BY \(unsafeRaw: TimelineController.localTime) ASC, sa.id
            LIMIT 500
            """).all(decoding: TimelineController.ItemRow.self)

        let items = rows.map { $0.toItem() }
        return SearchResults(items: items, total: items.count, nextOffset: nil)
    }

    // MARK: - Choosing a cover

    /// Orders a collection's photos so the first one is worth putting on a card.
    ///
    /// Random picks badly more often than it seems: a library is full of blurry
    /// frames, pocket shots and photographs of parking signs taken to remember
    /// where the car was, and any of them can end up representing a holiday.
    /// None of that needs a model to avoid — only an order of preference over
    /// columns that already exist.
    ///
    /// A photo the NAS has not rendered yet comes last, whatever else it has
    /// going for it. A cover is the one image on a card, and choosing one that
    /// cannot be drawn produces a grey rectangle where a photograph should be —
    /// while a perfectly good alternative sits in the same collection.
    ///
    /// The seed is the current date, so covers hold still all day and differ
    /// tomorrow. Rotating them *while someone is looking* would defeat the one
    /// job a cover has, which is to make a card recognisable.
    static func coverOrder(seed: String) -> String {
        """
        (a.derived_at IS NOT NULL) DESC,
        (a.camera_make IS NOT NULL) DESC,
        (a.burst_id IS NULL OR a.burst_pick) DESC,
        (a.media_type = 'photo') DESC,
        md5(a.id::text || '\(seed)')
        """
    }

    // MARK: - Formatting

    /// One calendar, fixed to UTC, used everywhere a date is taken apart.
    ///
    /// The dates here are wall-clock labels, not instants: `"2026-08-31"` from
    /// the phone means that calendar day, and `local_captured_at` is already the
    /// photo's own wall clock. Parsing that string as UTC midnight and then
    /// reading its components back through the *server's* calendar shifted the
    /// day by one anywhere west of Greenwich — so On This Day quietly asked for
    /// yesterday, found nothing, and showed no hero at all.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func parseDate(_ text: String) -> Date? {
        stampFormatter("yyyy-MM-dd").date(from: text)
    }

    /// Every formatter here is UTC, for the same reason the calendar is.
    ///
    /// These are wall-clock labels, not instants. A formatter left on the
    /// server's own zone renders 31 August as "30 August" anywhere west of
    /// Greenwich — which is how the hero came to be captioned with the day
    /// before the one it had just correctly selected.
    private static func stampFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static func dayStamp(_ date: Date) -> String {
        stampFormatter("yyyy-MM-dd").string(from: date)
    }

    private static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    /// "25 August 2019".
    private static func dayLabel(month: Int, day: Int, year: Int) -> String {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Self.utc.date(from: components) else {
            return "\(year)"
        }
        return stampFormatter("d MMMM yyyy").string(from: date)
    }

    /// "A busy Saturday" — the weekday is the part people actually recall about
    /// a day that mattered, more than its date.
    private static func weekdayTitle(_ key: String) -> String {
        guard let date = parseDate(key) else { return "A busy day" }
        return "A busy \(stampFormatter("EEEE").string(from: date))"
    }

    private static func longDay(_ key: String) -> String? {
        guard let date = parseDate(key) else { return nil }
        return stampFormatter("d MMMM yyyy").string(from: date)
    }
}
