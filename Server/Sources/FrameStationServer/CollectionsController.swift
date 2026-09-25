import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension CollectionsResponse: @retroactive Content {}
extension NameOccasionRequest: @retroactive Content {}
extension RestoreAssetsRequest: @retroactive Content {}
extension PurgeAssetsRequest: @retroactive Content {}

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
        protected.put("spaces", ":spaceID", "collections", "name", use: name)
        protected.get("spaces", ":spaceID", "collections", "deleted", use: deletedItems)
        protected.post("spaces", ":spaceID", "collections", "deleted", "restore", use: restore)
        protected.post("spaces", ":spaceID", "collections", "deleted", "purge", use: purge)
    }

    /// Below this a collection isn't worth a card. Three photos from one day is
    /// a coincidence, not an occasion.
    static let minimumItems = 4

    /// How many trips, and how many holidays and occasions, the page itself
    /// shows. The rest wait behind See All.
    ///
    /// Three of each, where it used to be up to eight trips, six busy days and
    /// four places you hadn't been — eighteen rows of the library's opinions
    /// before your own albums, and he found it overwhelming. The page's job is
    /// to offer a handful of things worth opening, not to list what it can
    /// compute; See All is there for anyone who wants the list.
    static let pageTrips = 3
    static let pageOccasions = 3
    /// What See All holds. Far more than the page and still bounded — a
    /// response that grows with the library forever is a page that gets slower
    /// every year.
    static let allTripsLimit = 40
    static let allOccasionsLimit = 60

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

        // The holiday table is built for the years the library actually holds
        // and no others. Trips need it too now: a short trip over a holiday is
        // named after the holiday.
        let years = try await libraryYears(spaceID: spaceID, on: req.sql)
        let holidays = Holidays.table(forYears: years)

        let onThisDay = try await onThisDayCollections(
            spaceID: spaceID, today: today, seed: seed, userID: device.userID, on: req.sql
        )
        let trips = try await trips(
            spaceID: spaceID, seed: seed, holidays: holidays, on: req.sql
        )

        // Days already inside a trip are not also occasions of their own. The
        // fortnight in the Outer Banks is one card, not one card plus fourteen,
        // and a Christmas spent away is already in the trip's name.
        let claimed = Set(trips.flatMap { Self.days(inKey: $0.key) })

        let occasions = try await occasions(
            spaceID: spaceID, seed: seed, userID: device.userID, years: years,
            holidays: holidays, excluding: claimed, on: req.sql
        )
        let deleted = try await recentlyDeleted(spaceID: spaceID, on: req.sql)
        let arrived = try await recentlyAdded(spaceID: spaceID, on: req.sql)
        let marked = try await favorites(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        let away = try await revisits(spaceID: spaceID, seed: seed, on: req.sql)
        let season = try await lastSeason(
            spaceID: spaceID, today: today, seed: seed, on: req.sql
        )
        let anniversaries = Self.anniversaries(of: trips, today: today)
        let types = try await mediaTypes(spaceID: spaceID, seed: seed, on: req.sql)
        let comingUp = Self.comingUp(occasions, today: today)

        // Anything anchored to *today* outranks everything else: this day in an
        // earlier year, the week you were away in one, or last year's Christmas
        // in the weeks before this one. Those are answers to "why open this
        // now", and the rest are answers to "what else is here".
        let anchored = ([onThisDay.first, comingUp] + anniversaries).compactMap { $0 }

        // The rest is a pool, and the pool is the point. A page that always
        // opens on the same card stops being looked at — so on a day with
        // nothing anchored to it, the hero moves: the latest trip, somewhere
        // you haven't been in years, last season, the latest occasion. Turned
        // by the date, so it holds still while you are looking and has changed
        // by tomorrow.
        let latestOccasion = occasions.first { $0.occasion != nil }?.summary
        let pool = ([trips.first, away.first, season, latestOccasion]).compactMap { $0 }

        let turn = Self.utc.ordinality(of: .day, in: .year, for: today) ?? 0
        var hero: CollectionSummary?
        if !anchored.isEmpty {
            hero = anchored[turn % anchored.count]
        } else if !pool.isEmpty {
            hero = pool[turn % pool.count]
        } else {
            hero = nil
        }

        // Last Christmas on top of the page in December needs saying why, or
        // it reads as the page being a year behind.
        if let chosen = hero, chosen.key == comingUp?.key,
           let name = occasions.first(where: { $0.summary.key == chosen.key })?.occasion {
            hero = chosen.withKicker("\(name.uppercased()) IS COMING UP")
        }

        // Whatever became the hero is not also listed below it. Matched on the
        // *key* rather than the id: an anniversary is a trip wearing a
        // different sentence, so comparing ids let "Two years ago you were in
        // Nags Head" sit directly above "Six days in Nags Head" — the same
        // photographs, twice, on one screen. Nor is the same place or the same
        // occasion from another year: last Christmas as the hero and the one
        // before it as a row is one idea said twice.
        let heroKey = hero?.key
        let heroOccasion = occasions.first { $0.summary.key == heroKey }?.occasion

        return CollectionsResponse(
            hero: hero,
            trips: Self.featuredTrips(
                trips.filter { $0.key != heroKey },
                today: today, heroPlace: hero.flatMap(Self.place(of:))
            ),
            days: Self.featuredOccasions(
                occasions.filter { $0.summary.key != heroKey },
                today: today, comingUp: comingUp, heroOccasion: heroOccasion
            ),
            // Somewhere you haven't been in years is a lovely thing to open on
            // and a list of four of them is a lot to scroll past, so they are
            // the hero some days and a row on none.
            revisits: [],
            mediaTypes: types,
            recentlyDeleted: deleted,
            recentlyAdded: arrived,
            favorites: marked,
            allTrips: trips,
            allOccasions: occasions.map(\.summary)
        )
    }

    /// The years the library holds, for tables that are built per year.
    private func libraryYears(spaceID: UUID, on sql: any SQLDatabase) async throws -> [Int] {
        struct YearRow: Decodable { let year: Int }
        return try await sql.raw("""
            SELECT DISTINCT EXTRACT(YEAR FROM \(unsafeRaw: TimelineController.localTime))::int AS year
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            """).all(decoding: YearRow.self).map(\.year)
    }

    // MARK: - Choosing the few

    /// The trips the page itself shows.
    ///
    /// The ones that meant most — see `weight` — and one per place. A family
    /// with a lake house goes there every other weekend, and three rows of "A
    /// weekend in Bay Lake" are one fact said three times. Listed newest first
    /// once chosen.
    static func featuredTrips(
        _ trips: [CollectionSummary], today: Date, heroPlace: String?
    ) -> [CollectionSummary] {
        let ranked = trips.sorted { a, b in
            let (wa, wb) = (weight(a, today: today), weight(b, today: today))
            return wa != wb ? wa > wb : a.key > b.key
        }
        var places = Set(heroPlace.map { [$0] } ?? [])
        var chosen: [CollectionSummary] = []
        for trip in ranked where chosen.count < pageTrips {
            guard places.insert(place(of: trip) ?? trip.key).inserted else { continue }
            chosen.append(trip)
        }
        return chosen.sorted { $0.key > $1.key }
    }

    /// The holidays and occasions the page itself shows.
    ///
    /// Only days that *are* something — a holiday, or a name somebody gave
    /// them. A busy Tuesday afternoon is a real thing, but on this page it was
    /// noise: the timeline already has it, and a row that can only say "A busy
    /// Saturday" is not an offer anyone takes up.
    ///
    /// Each occasion once — one Christmas rather than every Christmas in a row,
    /// which See All has. The one coming up first, then the ones that meant
    /// most. Listed newest first once chosen.
    static func featuredOccasions(
        _ occasions: [Occasion], today: Date,
        comingUp: CollectionSummary?, heroOccasion: String?
    ) -> [CollectionSummary] {
        // What somebody named counts double: they said it mattered.
        func score(_ candidate: Occasion) -> Double {
            let base = weight(candidate.summary, today: today)
            return candidate.summary.isNamed ? base * 2 : base
        }
        let ranked = occasions.filter { $0.occasion != nil }.sorted { a, b in
            let aSoon = a.summary.key == comingUp?.key
            let bSoon = b.summary.key == comingUp?.key
            if aSoon != bSoon { return aSoon }
            let (sa, sb) = (score(a), score(b))
            return sa != sb ? sa > sb : a.summary.key > b.summary.key
        }
        var seen = Set(heroOccasion.map { [$0] } ?? [])
        var chosen: [CollectionSummary] = []
        for candidate in ranked where chosen.count < pageOccasions {
            guard let name = candidate.occasion, seen.insert(name).inserted else { continue }
            chosen.append(candidate.summary)
        }
        return chosen.sorted { $0.key > $1.key }
    }

    /// How much a trip or an occasion is likely to mean: how many photographs
    /// it holds, fading gently with age.
    ///
    /// Photographs because they are the family's own vote — forty on Labor Day
    /// means Labor Day mattered, four means it didn't, whatever the calendar
    /// thinks of it. Fading so that last summer can beat a bigger summer from
    /// ten years ago, but gently: the fortnight in Maine is still worth offering
    /// three years on, where a hard cutoff at a year would drop it for a
    /// four-photo afternoon.
    static func weight(_ collection: CollectionSummary, today: Date) -> Double {
        let age = start(of: collection).map { today.timeIntervalSince($0) / (365.25 * 86_400) } ?? 10
        return Double(collection.count) / (1 + max(age, 0))
    }

    /// Where a card is — "Nags Head" from "Six days in Nags Head" — for keeping
    /// one card per place. Nil for cards that aren't anywhere in particular.
    static func place(of collection: CollectionSummary) -> String? {
        switch collection.kind {
        case .trip, .anniversary:
            return collection.title.range(of: " in ").map {
                String(collection.title[$0.upperBound...])
            }
        case .revisit:
            return collection.title
        default:
            return nil
        }
    }

    /// Last year's version of an occasion that is about to come round again —
    /// Christmas in the weeks before Christmas, a birthday the week before it.
    ///
    /// Only an earlier year's, never this year's own: a day that has only just
    /// happened is still in the timeline, and "remember this" about last
    /// Tuesday is not a memory. The soonest to come round wins, so the end of
    /// November brings back Thanksgiving before Christmas.
    ///
    /// Strictly ahead of today. On the day itself On This Day already has it.
    static func comingUp(_ occasions: [Occasion], today: Date) -> CollectionSummary? {
        guard let from = utc.date(byAdding: .day, value: 1, to: today),
              let to = utc.date(byAdding: .day, value: 30, to: today),
              let recent = utc.date(byAdding: .day, value: -60, to: today)
        else { return nil }
        let year = utc.component(.year, from: today)

        /// When this occasion next comes round inside the window, if it does.
        func anniversary(_ started: Date) -> Date? {
            let parts = utc.dateComponents([.month, .day], from: started)
            return [year, year + 1].lazy.compactMap { anniversaryYear -> Date? in
                var probe = DateComponents()
                probe.year = anniversaryYear
                probe.month = parts.month
                probe.day = parts.day
                // A 29 February probed in a year without one comes back as the
                // first of March; that is not its anniversary.
                guard let date = utc.date(from: probe),
                      utc.component(.day, from: date) == parts.day,
                      date >= from, date <= to else { return nil }
                return date
            }.first
        }

        // Newest first already, so among equally soon ones the first found is
        // the latest year's.
        var best: (date: Date, summary: CollectionSummary)?
        for candidate in occasions where candidate.occasion != nil {
            guard let started = start(of: candidate.summary), started < recent,
                  let next = anniversary(started) else { continue }
            if best == nil || next < best!.date { best = (next, candidate.summary) }
        }
        return best?.summary
    }

    /// The first day a trip or occasion covers, from its key.
    static func start(of collection: CollectionSummary) -> Date? {
        parseDate(String(collection.key.prefix(10)))
    }

    // MARK: - On this day

    private struct OnThisDayRow: Decodable {
        let year: Int
        let count: Int
        let coverAssetIDs: [UUID]
    }

    /// The same calendar day, in every earlier year that has photos.
    ///
    /// Matched on `local_captured_at` — the photo's own wall clock — so a
    /// picture taken at 9pm in Rome belongs to that evening and not to the next
    /// morning UTC. Getting this wrong shows the wrong day once a year to
    /// anyone who has traveled, which is the whole audience.
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
                   (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                       [1:\(unsafeRaw: String(Self.coverDepth))] AS "coverAssetIDs"
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
                subtitle: Self.dayLabel(month: month, day: day, year: row.year),
                count: row.count,
                coverAssetIDs: row.coverAssetIDs
            )
        }
    }

    // MARK: - Trips

    struct TripDay: Decodable {
        let day: String
        let count: Int
        /// Everywhere this day went, not just where most of it was.
        ///
        /// The daily mode was the first attempt and it quietly lost the point:
        /// a week on the Outer Banks moves between Nags Head, Kill Devil Hills
        /// and Duck every day, the mode collapses each day to one of them, and
        /// the trip ended up named after whichever won a tie — "Seven days in
        /// Duck" for a holiday that was nothing of the sort.
        let places: [String]
        let coverAssetIDs: [UUID]
    }

    /// Runs of consecutive days spent a long way from home.
    ///
    /// The whole of it is arithmetic. Home is the coordinate center of wherever
    /// the library has most of its photographs — for a family that is the house,
    /// and it needs no setting up and no asking. A day whose photographs average
    /// more than eighty kilometers from there was a day away. Consecutive days
    /// away are one trip.
    ///
    /// Eighty kilometers rather than ten: the bar has to clear the ordinary
    /// radius of a life. Work, school, the shops and the next town over are all
    /// "not home" and none of them are trips, and a threshold that called them
    /// trips would bury the fortnight in the Outer Banks under two hundred
    /// commutes.
    ///
    /// A single day that far away is a day out, not a trip, so a run has to
    /// span at least two.
    private func trips(
        spaceID: UUID, seed: String, holidays: [String: String], on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let local = TimelineController.localTime
        let rows = try await sql.raw("""
            WITH located AS (
                SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                       a.lat, a.lon, a.place_name, a.id, a.derived_at, a.camera_make,
                       a.burst_id, a.burst_pick, a.media_type
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                  AND a.lat IS NOT NULL AND a.lon IS NOT NULL
            ),
            -- Home: the center of the place the library holds most of.
            busiest AS (
                SELECT place_name FROM located
                WHERE place_name IS NOT NULL
                GROUP BY place_name ORDER BY count(*) DESC, place_name LIMIT 1
            ),
            home AS (
                SELECT avg(l.lat) AS lat, avg(l.lon) AS lon
                FROM located l JOIN busiest b ON b.place_name = l.place_name
            ),
            -- Places worth naming the day after: ones holding at least a fifth
            -- of it. A trip picks up stray coordinates — the drive home, a
            -- screenshot, someone else's phone with a stale fix — and a single
            -- outlier should not be able to turn "Four days in Bay Lake" into
            -- "Four days away" by making the town count look like two.
            per_place AS (
                SELECT day, place_name, count(*)::int AS n
                FROM located WHERE place_name IS NOT NULL
                GROUP BY day, place_name
            ),
            day_total AS (
                SELECT day, sum(n)::int AS total FROM per_place GROUP BY day
            ),
            main_places AS (
                SELECT p.day, ARRAY_AGG(p.place_name) AS places
                FROM per_place p JOIN day_total d ON d.day = p.day
                WHERE p.n * 5 >= d.total
                GROUP BY p.day
            ),
            per_day AS (
                SELECT day,
                       count(*)::int AS count,
                       avg(lat) AS lat, avg(lon) AS lon,
                       (ARRAY_AGG(id ORDER BY
                            (derived_at IS NOT NULL) DESC,
                            (camera_make IS NOT NULL) DESC,
                            (burst_id IS NULL OR burst_pick) DESC,
                            (media_type = 'photo') DESC,
                            md5(id::text || '\(unsafeRaw: seed)')
                        )) [1:\(unsafeRaw: String(Self.coverDepth))] AS cover
                FROM located GROUP BY day
            )
            SELECT p.day, p.count,
                   COALESCE(m.places, ARRAY[]::text[]) AS places,
                   p.cover AS "coverAssetIDs"
            FROM per_day p
            LEFT JOIN main_places m ON m.day = p.day
            CROSS JOIN home h
            WHERE h.lat IS NOT NULL
              AND 6371 * acos(LEAST(1, GREATEST(-1,
                    sin(radians(p.lat)) * sin(radians(h.lat))
                  + cos(radians(p.lat)) * cos(radians(h.lat))
                  * cos(radians(p.lon - h.lon))
                  ))) > \(bind: Self.awayKilometers)
            ORDER BY p.day DESC
            LIMIT 1000
            """).all(decoding: TripDay.self)

        // A thousand days away rather than four hundred, now that See All
        // reaches further back than the page does. Day trips count against it
        // too, and a family that drives to the coast most weekends used those
        // up within a couple of years.
        return Self.tripRuns(from: rows)
            .filter { $0.count >= 2 && $0.reduce(0) { $0 + $1.count } >= Self.minimumItems }
            .prefix(Self.allTripsLimit)
            .map { Self.describeTrip($0, holidays: holidays) }
    }

    /// How far from home stops being an errand.
    static let awayKilometers = 80

    /// Groups consecutive days into trips. Rows arrive newest-first.
    ///
    /// A single missing day doesn't end a trip — there are days on any holiday
    /// when nobody takes a photograph, and splitting a fortnight into two
    /// because of one rainy Tuesday would be worse than useless.
    static func tripRuns(from rows: [TripDay]) -> [[TripDay]] {
        var runs: [[TripDay]] = []
        for row in rows {
            if let previous = runs.last?.last,
               let earlier = parseDate(previous.day), let this = parseDate(row.day),
               let gap = utc.dateComponents([.day], from: this, to: earlier).day,
               gap >= 1, gap <= 2 {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }
        return runs
    }

    /// "Six days in Nags Head", or the state when the trip moved around inside
    /// one.
    ///
    /// A holiday on the Outer Banks touches Nags Head, Kill Devil Hills and
    /// Duck, and naming it after whichever had the most photographs would be
    /// arbitrary — the trip was to the coast. So several towns inside one region
    /// are named by the region, and a trip that crosses regions says neither.
    ///
    /// A week or less away over a holiday is named for the holiday — "Christmas
    /// 2024 in Asheville" is what the family calls it, and the days it covers
    /// are claimed by the trip, so it is the only card that can say so. A
    /// fortnight that happens to include Labor Day was not a Labor Day trip, and
    /// keeps its length.
    static func describeTrip(
        _ run: [TripDay], holidays: [String: String] = [:]
    ) -> CollectionSummary {
        let ordered = run.reversed().map { $0 }        // oldest first
        let count = run.reduce(0) { $0 + $1.count }
        let places = run.flatMap(\.places)
        let towns = Set(places.map { $0.split(separator: ",").first.map(String.init) ?? $0 })
        let regions = Set(places.compactMap {
            $0.split(separator: ",").dropFirst().first
                .map { $0.trimmingCharacters(in: .whitespaces) }
        })

        let where_: String?
        if towns.count == 1 {
            where_ = towns.first
        } else if regions.count == 1 {
            where_ = regions.first
        } else {
            where_ = nil
        }

        let weekdays = ordered.compactMap { parseDate($0.day) }
            .map { utc.component(.weekday, from: $0) }
        let phrase: String
        if run.count == 2, weekdays.contains(1), weekdays.contains(7) {
            phrase = "A weekend"
        } else if run.count == 3, weekdays.contains(1) || weekdays.contains(7) {
            phrase = "A long weekend"
        } else {
            phrase = "\(spelled(run.count).capitalized) days"
        }

        let holiday = run.count <= 7
            ? run.filter { holidays[$0.day] != nil }
                .max { $0.count < $1.count }
                .flatMap { day in holidays[day.day].map { "\($0) \(day.day.prefix(4))" } }
            : nil

        let title: String
        if let holiday {
            title = where_.map { "\(holiday) in \($0)" } ?? "\(holiday) away from home"
        } else {
            title = where_.map { "\(phrase) in \($0)" } ?? "\(phrase) away"
        }

        var parts: [String] = []
        if let from = ordered.first.flatMap({ parseDate($0.day) }),
           let to = ordered.last.flatMap({ parseDate($0.day) }) {
            let sameMonth = utc.component(.month, from: from) == utc.component(.month, from: to)
            // "12–16 August 2026" inside one month, "28 August – 2 September
            // 2024" across two. Abbreviating only the left-hand end read as a
            // mistake rather than as concision.
            let left = stampFormatter(sameMonth ? "d" : "d MMMM").string(from: from)
            let dash = sameMonth ? "–" : " – "
            parts.append("\(left)\(dash)\(stampFormatter("d MMMM yyyy").string(from: to))")
        }

        return CollectionSummary(
            kind: .trip,
            key: (ordered.first?.day ?? "") + ".." + (ordered.last?.day ?? ""),
            title: title,
            subtitle: parts.joined(separator: " · "),
            count: count,
            coverAssetIDs: Array(run.flatMap(\.coverAssetIDs).prefix(Self.coverDepth))
        )
    }

    // MARK: - Holidays and occasions

    /// A day that means something, and what it means.
    struct Occasion {
        let summary: CollectionSummary
        /// What the day *is* — "Christmas", "Mom's birthday" — without its year,
        /// so the page can offer each occasion once rather than every Christmas
        /// in a row. Nil for a date that only comes round busy every year,
        /// which See All offers to be named but the page doesn't lead with.
        let occasion: String?
    }

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
        let coverAssetIDs: [UUID]
    }

    /// Holidays, the days somebody named, and the dates that come round busy
    /// every year — newest first.
    ///
    /// Only those, where this used to be every day busier than usual. Busy is
    /// a fact about a day, not a reason to open it: most of them could only be
    /// called "A busy Saturday" or "An evening in Culpeper", and a page of those
    /// read as the library listing what it could compute. A day that is
    /// *something* — Christmas, "Sarah's engagement", the date you photograph
    /// every year — is worth a card however busy it was.
    ///
    /// A holiday or a named day clears a low bar: Christmas is not unusual, it
    /// is expected, and a quiet Christmas with six photographs is still
    /// Christmas. A date that only recurs has to be busy as well — against this
    /// library's own median day, because forty pictures is a quiet afternoon to
    /// one person and a wedding to another — or every date anyone photographs
    /// most years would qualify.
    ///
    /// Deliberately fetches far more days than it returns. Consecutive days are
    /// one occasion rather than several — Christmas Eve into Christmas morning
    /// is one Christmas — so the grouping happens after the query and the limit
    /// applies to the *runs*.
    private func occasions(
        spaceID: UUID, seed: String, userID: UUID, years: [Int],
        holidays: [String: String], excluding claimed: Set<String>,
        on sql: any SQLDatabase
    ) async throws -> [Occasion] {
        let local = TimelineController.localTime
        let named = try await occasionNames(
            spaceID: spaceID, userID: userID, years: years, on: sql
        )
        let recurring = try await recurringDates(spaceID: spaceID, on: sql)

        // Joined and split rather than interpolated: these strings are
        // machine-generated dates, but a query that builds its own IN list is a
        // habit worth not having.
        let special = Set(holidays.keys).union(named.keys).sorted().joined(separator: ",")
        let annual = recurring.sorted().joined(separator: ",")

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
                       (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                           [1:\(unsafeRaw: String(Self.coverDepth))] AS cover
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
                   p."firstHour", p."lastHour", p."peopleCount", p.cover AS "coverAssetIDs"
            FROM per_day p, baseline b
            WHERE (p.day = ANY(string_to_array(\(bind: special), ','))
                   AND p.count >= \(bind: Self.minimumItems))
               OR (substr(p.day, 6) = ANY(string_to_array(\(bind: annual), ','))
                   AND p.count >= GREATEST(b.median * 3, \(bind: Self.minimumItems * 2)))
            ORDER BY p.day DESC
            LIMIT 600
            """).all(decoding: DayRow.self)

        // A date that only recurs is offered once, in its latest year: what it
        // is asking for is a name, and one name covers every year of it.
        var offered = Set<String>()
        return Self.runs(from: rows.filter { !claimed.contains($0.day) })
            .compactMap {
                Self.occasion($0, holidays: holidays, named: named, recurring: recurring)
            }
            .filter { candidate in
                guard candidate.occasion == nil else { return true }
                return offered.insert(Self.monthDay(String(candidate.summary.key.prefix(10))))
                    .inserted
            }
            .prefix(Self.allOccasionsLimit)
            .map { $0 }
    }

    /// A run as an occasion: its card, and what it is.
    static func occasion(
        _ run: Run,
        holidays: [String: String],
        named: [String: String],
        recurring: Set<String>
    ) -> Occasion? {
        guard var summary = describe(
            run, holidays: holidays, named: named, recurring: recurring
        ) else { return nil }
        let name = run.days.compactMap { named[$0.day] }.first
            ?? holiday(in: run, holidays: holidays)?.name

        // A date photographed every year that nobody has named yet is almost
        // always a birthday or an anniversary, and saying so is the whole
        // reason to show it. "A busy Tuesday" told you nothing about why it was
        // here; this tells you, and the card offers to name it every year.
        if name == nil, summary.recursAnnually, let day = parseDate(run.first.day) {
            summary = CollectionSummary(
                kind: summary.kind, key: summary.key,
                title: "Every year on \(stampFormatter("d MMMM").string(from: day))",
                // The place back in: the old title carried it, this one doesn't.
                subtitle: subtitle(run, place: run.place), count: summary.count,
                coverAssetIDs: summary.coverAssetIDs, isNamed: summary.isNamed,
                recursAnnually: summary.recursAnnually
            )
        }
        return Occasion(summary: summary, occasion: name)
    }

    /// The holiday a run is, if it holds one. Where it holds two — Christmas
    /// Eve into Christmas morning — the busier names it, because that is the
    /// one people mean.
    static func holiday(
        in run: Run, holidays: [String: String]
    ) -> (name: String, day: String)? {
        run.days
            .filter { holidays[$0.day] != nil }
            .max { $0.count < $1.count }
            .flatMap { day in holidays[day.day].map { ($0, day.day) } }
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
    ///
    /// Nil when even that fails. A run of several days that happened nowhere in
    /// particular, on no named occasion, has nothing to be called except how
    /// long it was — and "Two days" is not a name, it is this function's
    /// working shown on the page. One of those on a page is enough to make the
    /// good titles beside it look accidental too, and a library ten times this
    /// size produces them by the hundred rather than by the fewer.
    ///
    /// Dropping it loses nothing: the photographs are in the timeline where
    /// they were taken, and the collection was only ever an offer to look at
    /// them a different way. An offer that cannot say what it is offering is
    /// better not made.
    static func describe(
        _ run: Run,
        holidays: [String: String] = [:],
        named: [String: String] = [:],
        recurring: Set<String> = []
    ) -> CollectionSummary? {
        let place = run.place
        let title: String
        // Whether the title already names where this happened, so the subtitle
        // doesn't say it twice — and, for a run that visited several places,
        // doesn't contradict a title that just said so.
        var titleNamedPlace = place != nil

        // A named day wins over everything. "Christmas 2024" is a better answer
        // than "An afternoon in Culpeper" even though both are true, and it is
        // the answer somebody scanning the page is actually looking for.
        //
        // What somebody typed beats everything the library worked out, including
        // the holiday table. If a person renamed the 25th "Christmas at the
        // lake", that is the better answer and it is not the app's place to
        // argue — nor to add a year to it, since renaming starts from the title
        // and a year would end up typed into a name that applies every year.
        let userName = run.days.compactMap { named[$0.day] }.first

        if let userName {
            title = userName
            titleNamedPlace = false
        } else if let holiday = holiday(in: run, holidays: holidays) {
            // With its year. "Christmas" alone was a card that could have been
            // any of ten Christmases until you read the line under it.
            title = "\(holiday.name) \(holiday.day.prefix(4))"
            titleNamedPlace = false
        } else if run.span > 1 {
            // Only when it can say where, or what kind of stretch it was. A
            // weekend is a thing; "four days" is a measurement.
            guard let earned = runTitle(run, place: place) else { return nil }
            title = earned
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
            coverAssetIDs: Array(run.days.flatMap(\.coverAssetIDs).prefix(Self.coverDepth)),
            isNamed: userName != nil,
            recursAnnually: run.days.contains { recurring.contains(monthDay($0.day)) }
        )
    }

    /// Every date a run key spans, so a trip can claim its own days.
    static func days(inKey key: String) -> [String] {
        let ends = key.components(separatedBy: "..")
        guard let first = ends.first.flatMap(parseDate),
              let last = ends.last.flatMap(parseDate) else { return ends }
        var result: [String] = []
        var cursor = first
        while cursor <= last, result.count < 400 {
            result.append(stampFormatter("yyyy-MM-dd").string(from: cursor))
            guard let next = utc.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// `"2026-08-14"` → `"08-14"`.
    static func monthDay(_ day: String) -> String {
        String(day.dropFirst(5))
    }

    /// Names a stretch of days. A weekend is worth recognising by name; four
    /// days in a row is worth counting.
    ///
    /// Nil where neither applies and there is no place to hang it on, which is
    /// the one case that produced titles like "Two days".
    private static func runTitle(_ run: Run, place: String?) -> String? {
        let weekdays = run.days.compactMap { parseDate($0.day) }
            .map { utc.component(.weekday, from: $0) }   // 1 = Sunday, 7 = Saturday
        let isWeekendPair = run.span == 2 && weekdays.contains(1) && weekdays.contains(7)
        let touchesWeekend = weekdays.contains(1) || weekdays.contains(7)

        let phrase: String
        if isWeekendPair {
            phrase = "A weekend"
        } else if run.span == 3, touchesWeekend {
            phrase = "A long weekend"
        } else if place != nil {
            // "Four days in Asheville" earns its place — the count is doing
            // real work once there is somewhere for it to have happened.
            phrase = "\(spelled(run.span).capitalized) days"
        } else {
            return nil
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
            let left = stampFormatter(sameMonth ? "d" : "d MMMM").string(from: from)
            let dash = sameMonth ? "–" : " – "
            parts.append("\(left)\(dash)\(stampFormatter("d MMMM yyyy").string(from: to))")
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

    // MARK: - What the person called it

    /// Every name this person has given a day in this space, keyed by
    /// `YYYY-MM-DD` for the years the library holds.
    ///
    /// Expanded here rather than matched in SQL because an annual name applies
    /// to a date in *every* year, and the alternative is a join with an OR
    /// across two shapes on every day row. Fetching the handful of rows a person
    /// has actually written and expanding them in memory is both cheaper and
    /// far easier to be sure about.
    ///
    /// A name for a specific year beats the annual one, so "Christmas at the
    /// lake" can apply to 2024 while "Christmas" carries on for every other.
    private func occasionNames(
        spaceID: UUID, userID: UUID, years: [Int], on sql: any SQLDatabase
    ) async throws -> [String: String] {
        struct NameRow: Decodable {
            let month: Int
            let day: Int
            let year: Int?
            let name: String
        }
        let rows = try await sql.raw("""
            SELECT month, day, year, name FROM occasion_names
            WHERE user_id = \(bind: userID) AND space_id = \(bind: spaceID)
            """).all(decoding: NameRow.self)
        guard !rows.isEmpty else { return [:] }

        var table: [String: String] = [:]
        // Annual first so a year-specific name written afterwards overwrites it.
        for row in rows where row.year == nil {
            for year in years {
                table[Self.key(year: year, month: row.month, day: row.day)] = row.name
            }
        }
        for row in rows {
            guard let year = row.year else { continue }
            table[Self.key(year: year, month: row.month, day: row.day)] = row.name
        }
        return table
    }

    /// Dates that are busy in three or more separate years.
    ///
    /// The app cannot know a date is a birthday. It can notice that you have
    /// photographs on it most years, which is the moment "name this, every year"
    /// stops being a question out of nowhere and becomes an observation the
    /// person will recognize. Three years rather than two: two is a coincidence
    /// often enough to make the prompt feel wrong.
    private func recurringDates(
        spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> Set<String> {
        struct Row: Decodable { let monthDay: String }
        let local = TimelineController.localTime
        let rows = try await sql.raw("""
            WITH per_day AS (
                SELECT to_char(\(unsafeRaw: local), 'MM-DD') AS "monthDay",
                       EXTRACT(YEAR FROM \(unsafeRaw: local))::int AS year,
                       count(*)::int AS count
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
                GROUP BY 1, 2
            )
            SELECT "monthDay" FROM per_day
            WHERE count >= \(bind: Self.minimumItems)
            GROUP BY "monthDay"
            HAVING count(DISTINCT year) >= 3
            """).all(decoding: Row.self)
        return Set(rows.map(\.monthDay))
    }

    static func key(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Names a day, or takes the name back off.
    ///
    /// Per user, always: two people in the same household remember the same
    /// afternoon differently, and neither should be able to rename it for the
    /// other.
    @Sendable
    func name(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(NameOccasionRequest.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        guard let date = Self.parseDate(input.day) else {
            throw Abort(.badRequest, reason: "That isn't a date.")
        }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw Abort(.badRequest, reason: "That isn't a date.")
        }

        let trimmed = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty name is a request to forget, not a name of no characters.
        guard let trimmed, !trimmed.isEmpty else {
            if input.everyYear {
                try await req.sql.raw("""
                    DELETE FROM occasion_names
                    WHERE user_id = \(bind: device.userID) AND space_id = \(bind: spaceID)
                      AND month = \(bind: month) AND day = \(bind: day) AND year IS NULL
                    """).run()
            } else {
                try await req.sql.raw("""
                    DELETE FROM occasion_names
                    WHERE user_id = \(bind: device.userID) AND space_id = \(bind: spaceID)
                      AND month = \(bind: month) AND day = \(bind: day) AND year = \(bind: year)
                    """).run()
            }
            return .noContent
        }

        guard trimmed.count <= 80 else {
            throw Abort(.badRequest, reason: "That name is too long for a card.")
        }

        // Two statements rather than one with a nullable conflict target: the
        // unique indexes are partial, so each shape needs the index that
        // actually covers it.
        if input.everyYear {
            try await req.sql.raw("""
                INSERT INTO occasion_names (user_id, space_id, month, day, year, name)
                VALUES (\(bind: device.userID), \(bind: spaceID), \(bind: month),
                        \(bind: day), NULL, \(bind: trimmed))
                ON CONFLICT (user_id, space_id, month, day) WHERE year IS NULL
                DO UPDATE SET name = EXCLUDED.name, updated_at = now()
                """).run()
        } else {
            try await req.sql.raw("""
                INSERT INTO occasion_names (user_id, space_id, month, day, year, name)
                VALUES (\(bind: device.userID), \(bind: spaceID), \(bind: month),
                        \(bind: day), \(bind: year), \(bind: trimmed))
                ON CONFLICT (user_id, space_id, month, day, year) WHERE year IS NOT NULL
                DO UPDATE SET name = EXCLUDED.name, updated_at = now()
                """).run()
        }
        return .noContent
    }

    // MARK: - Anniversaries

    /// The trip you were on this week, in an earlier year.
    ///
    /// Costs nothing beyond the trips already computed: a trip whose span
    /// covers today's date in a previous year is an anniversary of itself. It
    /// is also the single most direct thing this page can say — "a year ago you
    /// were in North Carolina" needs no explanation and lands immediately.
    static func anniversaries(
        of trips: [CollectionSummary], today: Date
    ) -> [CollectionSummary] {
        let parts = utc.dateComponents([.year, .month, .day], from: today)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return []
        }

        return trips.compactMap { trip -> CollectionSummary? in
            let ends = trip.key.components(separatedBy: "..")
            guard let from = ends.first.flatMap(parseDate),
                  let to = ends.last.flatMap(parseDate) else { return nil }
            let tripYear = utc.component(.year, from: from)
            let ago = year - tripYear
            guard ago >= 1 else { return nil }

            // Does today's date, moved back to the trip's year, land inside it?
            var probe = DateComponents()
            probe.year = tripYear
            probe.month = month
            probe.day = day
            guard let anchor = utc.date(from: probe), anchor >= from, anchor <= to else {
                return nil
            }

            // "in North Carolina" from "Seven days in North Carolina".
            let place = trip.title.range(of: " in ").map {
                String(trip.title[$0.upperBound...])
            }
            let title = place.map { "\(agoPhrase(ago)) you were in \($0)" }
                ?? "\(agoPhrase(ago)) you were away"

            return CollectionSummary(
                kind: .anniversary,
                key: trip.key,
                title: title,
                subtitle: trip.subtitle,
                count: trip.count,
                coverAssetIDs: trip.coverAssetIDs
            )
        }
    }

    private static func agoPhrase(_ years: Int) -> String {
        years == 1 ? "A year ago" : "\(spelled(years).capitalized) years ago"
    }

    // MARK: - Somewhere you haven't been

    private struct RevisitRow: Decodable {
        let place: String
        let count: Int
        let lastSeen: String
        let coverAssetIDs: [UUID]
    }

    /// A place the library knows well and hasn't seen in years.
    ///
    /// Quietly one of the better things a library can notice about itself. It
    /// needs no cleverness — a place with a decent number of photographs whose
    /// most recent one is old — and it surfaces exactly the corners that a
    /// timeline buries, because the only way to reach 2021 by scrolling is to
    /// scroll through everything since.
    private func revisits(
        spaceID: UUID, seed: String, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let local = TimelineController.localTime
        let rows = try await sql.raw("""
            SELECT a.place_name AS place,
                   count(*)::int AS count,
                   to_char(max(\(unsafeRaw: local)), 'YYYY-MM-DD') AS "lastSeen",
                   (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                       [1:\(unsafeRaw: String(Self.coverDepth))] AS "coverAssetIDs"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
            GROUP BY a.place_name
            HAVING count(*) >= \(bind: Self.minimumItems * 3)
               AND max(\(unsafeRaw: local)) < now() - interval '2 years'
            ORDER BY max(\(unsafeRaw: local)) DESC
            LIMIT 4
            """).all(decoding: RevisitRow.self)

        return rows.map { row in
            let town = row.place.split(separator: ",").first.map(String.init) ?? row.place
            let when = Self.parseDate(row.lastSeen)
                .map { Self.stampFormatter("MMMM yyyy").string(from: $0) }
            return CollectionSummary(
                kind: .revisit,
                key: row.place,
                title: town,
                subtitle: when.map { "Last there in \($0)" },
                count: row.count,
                coverAssetIDs: row.coverAssetIDs
            )
        }
    }

    // MARK: - Seasons

    private struct SeasonRow: Decodable {
        let count: Int
        let coverAssetIDs: [UUID]
    }

    /// The most recent season that has finished.
    ///
    /// Only a completed one: "last winter" while it is still February is a
    /// season you are standing in, and a page offering to reminisce about this
    /// morning is a page that has run out of things to say.
    private func lastSeason(
        spaceID: UUID, today: Date, seed: String, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        guard let season = Self.completedSeason(before: today) else { return nil }
        let local = TimelineController.localTime
            // `::int` on both binds, and not decoration. Swift's `Int` binds as
            // BIGINT, and Postgres will not implicitly narrow that for a named
            // `make_interval` argument or an array subscript — so without the
            // casts this query raised, and because it is built alongside every
            // other collection it took the *whole* Albums page down with it. A
            // 500 on one new row is not a missing row, it is an empty page.
        let row = try await sql.raw("""
            SELECT count(*)::int AS count,
                   COALESCE(
                       (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                           [1:\(unsafeRaw: String(Self.coverDepth))],
                       ARRAY[]::uuid[]
                   ) AS "coverAssetIDs"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND to_char(\(unsafeRaw: local), 'YYYY-MM-DD')
                  BETWEEN \(bind: season.from) AND \(bind: season.to)
            """).first(decoding: SeasonRow.self)

        guard let row, row.count >= Self.minimumItems * 4 else { return nil }
        return CollectionSummary(
            kind: .season,
            key: "\(season.from)..\(season.to)",
            title: season.name,
            subtitle: season.span,
            count: row.count,
            coverAssetIDs: row.coverAssetIDs
        )
    }

    struct Season {
        let name: String
        let span: String
        let from: String
        let to: String
    }

    /// Northern-hemisphere seasons, matching the household this is for and the
    /// same assumption the holiday table already makes.
    static func completedSeason(before today: Date) -> Season? {
        let year = utc.component(.year, from: today)
        let month = utc.component(.month, from: today)

        // Each entry: the season that has most recently *ended* by this month.
        switch month {
        case 3...5:
            return Season(name: "Last winter", span: "December \(year - 1) – February \(year)",
                          from: "\(year - 1)-12-01", to: "\(year)-02-29")
        case 6...8:
            return Season(name: "Last spring", span: "March – May \(year)",
                          from: "\(year)-03-01", to: "\(year)-05-31")
        case 9...11:
            return Season(name: "Last summer", span: "June – August \(year)",
                          from: "\(year)-06-01", to: "\(year)-08-31")
        default:
            return Season(name: "Last autumn", span: "September – November \(year)",
                          from: "\(year)-09-01", to: "\(year)-11-30")
        }
    }

    // MARK: - Recently deleted

    private struct DeletedRow: Decodable {
        let count: Int
        let coverAssetID: UUID?
    }

    /// Removals inside their retention window, for a personal space only.
    ///
    /// Shared-space removals are recovered through File Station rather than
    /// here — see ARCHITECTURE.md. Offering a restore in a shared space would
    /// mean deciding who is allowed to undo whose deletion, and DSM already has
    /// an answer for that.
    ///
    /// This used to read `recycled_path` and stat the file, because the bytes
    /// sat in a bin DSM could empty from under us and a row was no proof the
    /// file was there. Retention moved the bytes back into the blob store,
    /// where nothing else reclaims them, so `purged_at` is now the whole
    /// answer — one column, no filesystem round trip per row.
    private func recentlyDeleted(
        spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        struct KindRow: Decodable { let kind: String }
        let space = try await sql.raw("""
            SELECT kind FROM spaces WHERE id = \(bind: spaceID)
            """).first(decoding: KindRow.self)
        guard space?.kind == "personal" else { return nil }

        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
            SELECT count(*) AS count
            FROM space_assets sa
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NOT NULL
              AND sa.purged_at IS NULL
            """).first(decoding: CountRow.self)

        guard let count = row?.count, count > 0 else { return nil }

        return CollectionSummary(
            kind: .recentlyDeleted,
            key: "all",
            title: "Recently Deleted",
            subtitle: nil,
            count: count,
            coverAssetIDs: []
        )
    }

    /// What has arrived lately, by upload time rather than capture time.
    ///
    /// Every other collection on this page is built from when a photograph was
    /// *taken*, which is the right axis for remembering and the wrong one for
    /// reassurance. Restore an old shoebox of scans and they land in 1974,
    /// correctly, and nowhere near anything that says they arrived safely.
    ///
    /// Thirty days, and only when something is in it — an empty "Recently
    /// Added" is a row that says the app is not being used.
    private func recentlyAdded(
        spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        struct Row: Decodable {
            let count: Int
            let coverAssetIDs: [UUID]?
        }
        let row = try await sql.raw("""
            SELECT count(*)::int AS count,
                   (array_agg(a.id ORDER BY sa.uploaded_at DESC))[1:\(bind: Self.coverDepth)::int]
                       AS "coverAssetIDs"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND sa.uploaded_at >= now() - make_interval(days => \(bind: Self.recentlyAddedDays)::int)
            """).first(decoding: Row.self)

        guard let row, row.count > 0 else { return nil }
        return CollectionSummary(
            kind: .recentlyAdded,
            key: String(Self.recentlyAddedDays),
            title: "Recently Added",
            subtitle: "Last \(Self.recentlyAddedDays) days",
            count: row.count,
            coverAssetIDs: row.coverAssetIDs ?? []
        )
    }

    /// The photographs this person marked, in this space.
    ///
    /// The only collection on the page that is nobody's inference. Everything
    /// else is the library saying "you might want this"; a favorite is the
    /// person having already said so, which is why it belongs near the top and
    /// why it never needs a rule about when to show it — if it is empty there
    /// is nothing to show, and if it is not, they put it there on purpose.
    ///
    /// Keyed on the viewer as well as the space, so two people in one shared
    /// album each see their own.
    private func favorites(
        spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        struct Row: Decodable {
            let count: Int
            let coverAssetIDs: [UUID]?
        }
        let row = try await sql.raw("""
            SELECT count(*)::int AS count,
                   (array_agg(a.id ORDER BY f.favorited_at DESC))[1:\(bind: Self.coverDepth)::int]
                       AS "coverAssetIDs"
            FROM space_asset_favorites f
            JOIN space_assets sa ON sa.id = f.space_asset_id
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND f.user_id = \(bind: userID)
              AND sa.deleted_at IS NULL
            """).first(decoding: Row.self)

        guard let row, row.count > 0 else { return nil }
        return CollectionSummary(
            kind: .favorites,
            key: "all",
            title: "Favorites",
            subtitle: nil,
            count: row.count,
            coverAssetIDs: row.coverAssetIDs ?? []
        )
    }

    static let recentlyAddedDays = 30

    // MARK: - Media types

    private struct TypeRow: Decodable {
        let count: Int
        let coverAssetIDs: [UUID]
    }

    /// The file-shaped collections, each behind its own count.
    ///
    /// Every one of these is a `WHERE` clause over columns that already exist —
    /// there is no detection here and nothing to get wrong. They are listed
    /// last and behind one heading because that is what they are worth: a way
    /// to find every video you have, not a way to remember a holiday.
    ///
    /// A type with nothing in it is absent rather than shown as zero, which is
    /// the same rule the rest of the page follows.
    private func mediaTypes(
        spaceID: UUID, seed: String, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        // (key, title, predicate)
        var kinds: [(String, String, SQLQueryString)] = [
            ("video", "Videos", "a.media_type = 'video'"),
            ("live", "Live Photos", "a.live_group_id IS NOT NULL"),
            ("burst", "Bursts", "a.burst_id IS NOT NULL"),
        ]
        // Everything the device told us about itself. Ordered by how much of a
        // library each usually accounts for, so the common ones lead.
        for subtype in [
            MediaSubtype.screenshot, .panorama, .portrait,
            .slomo, .timelapse, .screenRecording, .cinematic,
        ] {
            kinds.append((subtype.rawValue, subtype.title, Self.subtypeFilter(subtype)))
        }
        kinds.append(("raw", "RAW", "a.is_raw"))

        var result: [CollectionSummary] = []
        for (key, title, predicate) in kinds {
            let row = try await sql.raw("""
                SELECT count(*)::int AS count,
                       -- ARRAY_AGG over nothing is NULL, not an empty array, and
                       -- a media type with no photographs is the normal case
                       -- rather than the exception — most libraries hold no RAW
                       -- and no panoramas at all. Decoding ran before the count
                       -- check could skip the row, so one absent type failed the
                       -- whole page with a 500.
                       COALESCE(
                           (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                               [1:\(unsafeRaw: String(Self.coverDepth))],
                           ARRAY[]::uuid[]
                       ) AS "coverAssetIDs"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                  AND \(predicate)
                """).first(decoding: TypeRow.self)
            guard let row, row.count >= 1 else { continue }
            result.append(CollectionSummary(
                kind: .mediaType,
                key: key,
                title: title,
                subtitle: nil,
                count: row.count,
                coverAssetIDs: row.coverAssetIDs
            ))
        }
        return result
    }

    /// What makes an asset one of these types.
    ///
    /// The device's own answer where there is one, and the old guess only for
    /// assets that have none — anything uploaded before subtypes existed, or
    /// imported from disk by the `import` CLI, which has no PhotoKit to ask.
    ///
    /// The `media_subtypes = '{}'` guard is what keeps the fallback from
    /// undoing the fix. Without it a photograph the device explicitly did *not*
    /// call a screenshot would still be caught by "PNG, no camera", and being
    /// precise about the new rows would have bought nothing.
    static func subtypeFilter(_ subtype: MediaSubtype) -> SQLQueryString {
        let tag = SQLQueryString(stringLiteral: "'\(subtype.rawValue)'")
        guard let guess = Self.legacyGuess(subtype) else {
            return "\(tag) = ANY(a.media_subtypes)"
        }
        return "(\(tag) = ANY(a.media_subtypes) OR (a.media_subtypes = '{}' AND \(guess)))"
    }

    /// How the server used to infer a subtype, kept only for rows recorded
    /// before the device started telling us. Nil where there was never a guess
    /// worth making — a screen recording is indistinguishable from any other
    /// video on disk, so claiming otherwise would invent data.
    private static func legacyGuess(_ subtype: MediaSubtype) -> SQLQueryString? {
        switch subtype {
        case .screenshot:
            return "a.camera_make IS NULL AND a.media_type = 'photo' AND a.mime = 'image/png'"
        case .panorama:
            return "a.width IS NOT NULL AND a.height > 0 AND a.width::float / a.height >= 2"
        case .screenRecording, .slomo, .timelapse, .portrait, .cinematic:
            return nil
        }
    }

    /// The `WHERE` clause behind one media type, for opening it.
    static func mediaTypeFilter(_ key: String) -> SQLQueryString? {
        if let subtype = MediaSubtype(rawValue: key) {
            return "AND \(subtypeFilter(subtype))"
        }
        switch key {
        case "video": return "AND a.media_type = 'video'"
        case "live": return "AND a.live_group_id IS NOT NULL"
        case "burst": return "AND a.burst_id IS NOT NULL"
        case "raw": return "AND a.is_raw"
        default: return nil
        }
    }

    // MARK: - Recently deleted, opened

    /// What is still in the bin and still on disk.
    ///
    /// Every row is checked against the filesystem before it is offered. The bin
    /// carries DSM's own name so File Station treats it as a recycle bin, which
    /// means DSM's scheduled emptying can reclaim the bytes underneath us — and
    /// a list that offered a restore which then failed on tap would be the one
    /// way this feature could actively lie.
    @Sendable
    func deletedItems(req: Request) async throws -> SearchResults {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let rows = try await req.sql.raw("""
            SELECT sa.id,
                   sa.space_id   AS "spaceID",
                   a.id          AS "assetID",
                   \(unsafeRaw: TimelineController.localTime) AT TIME ZONE 'UTC' AS "capturedAt",
                   a.width, a.height, a.orientation,
                   a.media_type  AS "mediaType",
                   a.duration_ms AS "durationMs",
                   a.thumbhash   AS "thumbHash",
                   false         AS "isFavorite",
                   COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id) AS "uploadedBy",
                   (a.derived_at IS NOT NULL) AS "isDerived",
                   -- The day this becomes unrecoverable, computed here so the
                   -- client never has to know the window to count down to it.
                   (sa.deleted_at + \(unsafeRaw: Retention.interval)) AT TIME ZONE 'UTC'
                       AS "purgeAt"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NOT NULL
              AND sa.purged_at IS NULL
            ORDER BY sa.deleted_at DESC
            LIMIT 500
            """).all(decoding: DeletedItemRow.self)

        let items = rows.map { $0.item.toItem() }
        return SearchResults(items: items, total: items.count, nextOffset: nil)
    }

    struct DeletedItemRow: Decodable {
        let id: UUID
        let spaceID: UUID
        let assetID: UUID
        let capturedAt: Date
        let width: Int?
        let height: Int?
        let mediaType: String
        let durationMs: Int?
        let thumbHash: Data?
        let isFavorite: Bool
        let uploadedBy: UUID
        let isDerived: Bool
        let orientation: Int?
        let purgeAt: Date

        var item: TimelineController.ItemRow {
            TimelineController.ItemRow(
                id: id, spaceID: spaceID, assetID: assetID, capturedAt: capturedAt,
                width: width, height: height, mediaType: mediaType, durationMs: durationMs,
                thumbHash: thumbHash, isFavorite: isFavorite, uploadedBy: uploadedBy,
                isDerived: isDerived, orientation: orientation, purgeAt: purgeAt
            )
        }
    }

    /// Puts photographs back.
    ///
    /// Clearing `deleted_at` is the whole of it. This used to move a file out of
    /// `#recycle` and undo the delete only if that move succeeded — necessary
    /// then, because deleting had moved the bytes somewhere restoring had to
    /// find them again. Nothing moves the bytes now: they never left the blob
    /// store, and the browse-tree reconciler puts the copy back in each member's
    /// home on its next sweep, exactly as it would for a new upload.
    ///
    /// Rows past their window are excluded. `purged_at` means the bytes are
    /// gone, so restoring one would return a photograph that could never load.
    @Sendable
    func restore(req: Request) async throws -> MediaEditResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(RestoreAssetsRequest.self)
        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        struct Row: Decodable {
            let id: UUID
            let assetID: UUID
        }

        var restored = 0
        for assetID in input.assetIDs.prefix(500) {
            guard let row = try await req.sql.raw("""
                SELECT sa.id, sa.asset_id AS "assetID"
                FROM space_assets sa
                WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
                  AND sa.deleted_at IS NOT NULL
                  AND sa.purged_at IS NULL
                """).first(decoding: Row.self) else { continue }

            try await req.sql.raw("""
                UPDATE space_assets
                SET deleted_at = NULL, deleted_by = NULL
                WHERE id = \(bind: row.id)
                """).run()
            _ = try? await ChangeLog.append(
                spaceID: spaceID, entity: "space_asset", entityID: row.id,
                op: "insert", on: req.sql
            )
            restored += 1
        }
        return MediaEditResponse(updated: restored)
    }

    /// Deletes chosen removals now, ahead of the sweep — "Delete Permanently".
    ///
    /// Only rows that are already removed and not yet purged, and only in a
    /// space the caller contributes to — the same gate as restore, since the
    /// person who could put a photo back is the person who may finish deleting
    /// it. Each teardown runs through the very code the retention sweeper uses,
    /// so a photo deleted by hand and one that ran out its 29 days leave the
    /// disk in exactly the same state. Irreversible past this point; the client
    /// confirms before calling.
    @Sendable
    func purge(req: Request) async throws -> MediaEditResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(PurgeAssetsRequest.self)
        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        struct Row: Decodable {
            let id: UUID
            let sha256: String
            let blobExt: String
        }

        var purged = 0
        for assetID in input.assetIDs.prefix(500) {
            guard let row = try await req.sql.raw("""
                SELECT sa.id, a.sha256, a.blob_ext AS "blobExt"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID) AND sa.asset_id = \(bind: assetID)
                  AND sa.deleted_at IS NOT NULL
                  AND sa.purged_at IS NULL
                """).first(decoding: Row.self) else { continue }

            await RetentionWorker.purge(
                placementID: row.id, sha256: row.sha256, blobExt: row.blobExt,
                on: req.sql, blobStore: req.blobStore, logger: req.logger
            )
            purged += 1
        }
        return MediaEditResponse(updated: purged)
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
        case .day, .trip:
            // Both carry a run key: a single date, or "first..last". Matching on
            // the range rather than the enumerated days keeps the query one
            // comparison wide however long the holiday was.
            let ends = key.components(separatedBy: "..")
            let from = ends.first ?? key
            let to = ends.last ?? key
            filter = """
                AND to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD')
                    BETWEEN \(bind: from) AND \(bind: to)
                """
        case .anniversary, .season:
            // Both are date ranges, like a trip.
            let ends = key.components(separatedBy: "..")
            filter = """
                AND to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD')
                    BETWEEN \(bind: ends.first ?? key) AND \(bind: ends.last ?? key)
                """
        case .revisit:
            // Keyed by place rather than by date — the whole point of it is
            // everything from somewhere, whenever that was.
            filter = "AND a.place_name = \(bind: key)"
        case .mediaType:
            guard let predicate = Self.mediaTypeFilter(key) else {
                throw Abort(.badRequest, reason: "No such media type.")
            }
            filter = predicate
        case .favorites:
            filter = """
                AND EXISTS (
                    SELECT 1 FROM space_asset_favorites f
                    WHERE f.space_asset_id = sa.id
                      AND f.user_id = \(bind: device.userID)
                )
                """
        case .recentlyAdded:
            // Days, from the key. The only collection keyed by a window rather
            // than by a date or a place, because it is the only one that means
            // "lately" rather than "then".
            let days = Int(key) ?? Self.recentlyAddedDays
            filter = """
                AND sa.uploaded_at >= now() - make_interval(days => \(bind: days)::int)
                """
        case .recentlyDeleted:
            throw Abort(.badRequest, reason: "Recently Deleted has its own endpoint.")
        }

        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
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
    /// cannot be drawn produces a gray rectangle where a photograph should be —
    /// while a perfectly good alternative sits in the same collection.
    ///
    /// The seed is the current date, so covers hold still all day and differ
    /// tomorrow. Rotating them *while someone is looking* would defeat the one
    /// job a cover has, which is to make a card recognisable.
    /// How many photographs to send for a card.
    ///
    /// Five is what the hero cycles through. Sending them costs nothing — they
    /// are ids in a response that was being built anyway — and only the hero
    /// actually fetches beyond the first.
    static let coverDepth = 5

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
