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
/// In a person's own library the arithmetic also counts what their own devices
/// saw in the photographs, so a day can turn out to have been a birthday party
/// and a holiday has to look like one. The looking happened on the device; here
/// it is only counted. See "What the photographs showed" and
/// `CurationVocabulary`.
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
    /// And it needs this many moments (minutes with photos in them) to be
    /// worth opening: a burst is one, so a burst and a stray isn't an album.
    /// A birthday with a few candle shots still is. A holiday says what it is
    /// with fewer.
    static let minimumMoments = 3
    static let holidayMoments = 2
    /// A trip needs more: being away is its whole reason, and two days with
    /// a burst, a photo saved twice and a candy board in them were "A weekend
    /// in Linton Hall" (his example, 2026-11-10). Half a dozen moments is the
    /// least of a weekend anyone would open.
    static let tripMoments = 6

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
    /// What a page with room for a whole row of cards gets of each, chosen by
    /// the same rules: the Mac's page, which runs six to nine across.
    static let wideLimit = 12

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
        // stays recognizable for as long as anyone is looking at it.
        let seed = Self.dayStamp(today)

        // What the person's own devices saw, for their own library. Empty
        // anywhere else, or with curation turned off, and then the page is
        // exactly what it was before curation existed. See `CurationVocabulary`.
        let curation = try await CurationController.context(
            userID: device.userID, spaceID: spaceID, on: req.sql
        )
        let evidence = curation.enabled && curation.isPersonal
            ? try await dayEvidence(
                spaceID: spaceID, userID: device.userID, source: curation.source, on: req.sql
            )
            : [:]

        // The holiday table is built for the years the library actually holds
        // and no others. Trips need it too now: a short trip over a holiday is
        // named after the holiday.
        //
        // Turned off, there are no holidays at all, here or in trip names. On,
        // a holiday the devices have looked at has to look like itself.
        let years = try await libraryYears(spaceID: spaceID, on: req.sql)
        let calendar = curation.holidays ? Holidays.table(forYears: years) : [:]
        let holidays = Self.evidenced(calendar, by: evidence)
        let events = Self.events(in: evidence, excluding: holidays)

        let onThisDay = try await onThisDayCollections(
            spaceID: spaceID, today: today, seed: seed, userID: device.userID, on: req.sql
        )
        // Kept as they were shown, so improving the rules below never makes
        // an album someone knows disappear. See `CuratedAlbums`.
        let keeper = CuratedAlbums(
            spaceID: spaceID, userID: device.userID, sql: req.sql, logger: req.logger,
            persists: curation.persistsAlbums
        )
        let saved = await keeper.load()

        // Every trip the library holds, for the ones a family takes every
        // year (see `tripTraditions`); the page and See All show the latest.
        let everyTrip = try await trips(
            spaceID: spaceID, seed: seed, userID: device.userID,
            holidays: holidays, evidence: evidence, geocoder: req.application.geocoder,
            on: req.sql
        )
        let trips = await keeper.keep(
            trips: Array(everyTrip.prefix(Self.allTripsLimit)),
            saved: saved, limit: Self.allTripsLimit, seed: seed
        )

        // Days already inside a trip are not also occasions of their own. Two
        // weeks on the Outer Banks are one card, not one card plus fourteen,
        // and a Christmas spent away is already in the trip's name.
        let claimed = Set(trips.flatMap { Self.days(inKey: $0.key) })

        let named = try await occasionNames(
            spaceID: spaceID, userID: device.userID, years: years, on: req.sql
        )
        // What of each event day was the event, so its album is the party and
        // not the morning at the pool before it. See `EventScope`.
        let scope = curation.enabled && curation.isPersonal
            ? try await Self.eventScope(
                spaceID: spaceID, userID: device.userID, source: curation.source,
                events: events, named: named, on: req.sql
            )
            : EventScope()

        // What comes round every year, planned from the library's calendar
        // before the occasions query, so that query brings back every year of
        // each. See `YearlyPatterns`.
        let library = try await libraryDays(spaceID: spaceID, on: req.sql)
        let annual = try await annualNames(spaceID: spaceID, userID: device.userID, on: req.sql)
        let yearly = YearlyPatterns.plan(
            days: library, years: years, today: today,
            holidays: holidays, calendar: calendar, named: named, annual: annual,
            events: events, evidence: evidence, claimed: claimed
        )
        let found = try await occasions(
            spaceID: spaceID, seed: seed, userID: device.userID, named: named,
            holidays: holidays, events: events, excluding: claimed,
            recurring: library.recurring, yearly: yearly, scope: scope, on: req.sql
        )
        let occasions = await keeper.keep(
            occasions: found.occasions,
            saved: saved, claimed: claimed, outside: scope.filter,
            standing: CuratedAlbums.Standing(
                named: named, showEvents: curation.enabled, showHolidays: curation.holidays,
                // A holiday shown on its date alone is the person's analysis
                // still to come, which can withdraw it.
                unseen: Set(calendar.filter { Self.looksLike($1, on: $0, by: evidence) == nil }.keys),
                unlike: Set(calendar.keys).subtracting(holidays.keys)
            ),
            limit: Self.allOccasionsLimit, seed: seed
        )
        let deleted = try await recentlyDeleted(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        let arrived = try await recentlyAdded(spaceID: spaceID, on: req.sql)
        let marked = try await favorites(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        let away = try await revisits(
            spaceID: spaceID, seed: seed, userID: device.userID, on: req.sql
        )
        let season = try await lastSeason(
            spaceID: spaceID, today: today, seed: seed, userID: device.userID, on: req.sql
        )
        let anniversaries = Self.anniversaries(of: trips, today: today)
        let types = try await mediaTypes(
            spaceID: spaceID, seed: seed, userID: device.userID, on: req.sql
        )
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

        let traditions = yearly.traditions(
            rows: found.rows, today: today, turn: turn,
            holidays: holidays, named: named, annual: annual, events: events
        )
        // Which tradition each day is a year of, so Holidays & Occasions can
        // leave Christmas 2023 to the Christmas card above it, in an app that
        // shows one. See `CollectionSummary.tradition`.
        var yearOf: [String: String] = [:]
        for tradition in traditions {
            for year in tradition.years {
                for day in Self.days(inKey: year.key) { yearOf[day] = tradition.id }
            }
        }
        func yearMarked(_ card: CollectionSummary) -> CollectionSummary {
            guard let tradition = Self.days(inKey: card.key).lazy.compactMap({ yearOf[$0] }).first
            else { return card }
            return card.inTradition(tradition)
        }

        // The row the page opens on, the way Photos opens on its featured
        // memories and photos: a handful of cards to swipe, each with its own
        // reason to be looked at today. What's tied to today comes first, then
        // the day's highlights with a featured photo or two between them. All
        // turned by the date, so each day starts somewhere new and the row
        // holds still while you're looking at it. The first card is `hero`,
        // all an older app draws.
        let photos = curation.enabled && curation.isPersonal
            ? try await featuredPhotos(
                spaceID: spaceID, userID: device.userID, today: today, seed: seed, on: req.sql
            )
            : []
        var featured = Self.featuredRow(
            today: Self.rotated(anchored, by: turn),
            highlights: Self.rotated(pool, by: turn),
            photos: photos
        )

        // Last Christmas on top of the page in December needs saying why, or
        // it reads as the page being a year behind.
        if let comingUp, let name = occasions.first(where: { $0.summary.key == comingUp.key })?.occasion,
           let index = featured.firstIndex(where: { $0.key == comingUp.key }) {
            featured[index] = featured[index].withKicker("\(name.uppercased()) IS COMING UP")
        }
        let hero = featured.first

        // Whatever became the hero is not also listed below it. Matched on the
        // *key* rather than the id: an anniversary is a trip wearing a
        // different sentence, so comparing ids let "Two years ago you were in
        // Nags Head" sit directly above "Six days in Nags Head" — the same
        // photographs, twice, on one screen. Nor is the same place or the same
        // occasion from another year: last Christmas as the hero and the one
        // before it as a row is one idea said twice.
        let heroKey = hero?.key
        let heroOccasion = occasions.first { $0.summary.key == heroKey }?.occasion
        // Every card in the top row, not only the first: one swipe brings any
        // of them up above the sections, and the same trip there and in a row
        // just below it is the same photographs twice on one screen.
        let featuredKeys = Set(featured.map(\.key))

        let unfeaturedTrips = trips.filter { !featuredKeys.contains($0.key) }
        let unfeaturedOccasions = occasions.filter { !featuredKeys.contains($0.summary.key) }

        // The people in the owner's own library, for someone the NAS
        // analyzes with People on. Nil for anyone else and any other library,
        // so no row.
        let people = curation.showsPeople
            ? try await PeopleController.summaries(
                userID: device.userID, spaceID: spaceID, limit: PeopleController.pageLimit, on: req.sql
            )
            : nil

        // Named for the people in them, where it plainly fits: "Celebrating
        // Thomas's 2nd Birthday", "Deem Christmas 2023", "Jack's Soccer
        // Game". Added as the page is drawn and never kept, so each name the
        // owner gives shows up at once, and goes again with it or with People.
        // A name the owner gave an album is never touched. See `withPeople`.
        let whoIsWho = curation.showsPeople
            ? try await Self.namedPeople(spaceID: spaceID, userID: device.userID, scope: scope, on: req.sql)
            : NamedPeople()
        let occasionByKey = Dictionary(occasions.map { ($0.summary.key, $0) }, uniquingKeysWith: { first, _ in first })
        func mark(_ card: CollectionSummary) -> CollectionSummary {
            Self.withPeople(card, people: whoIsWho, occasion: occasionByKey[card.key])
        }

        return CollectionsResponse(
            hero: hero.map(mark),
            trips: Self.featuredTrips(
                unfeaturedTrips, today: today, heroPlace: hero.flatMap(Self.place(of:))
            ).map(mark),
            days: Self.featuredOccasions(
                unfeaturedOccasions, today: today, comingUp: comingUp, heroOccasion: heroOccasion
            ).map(yearMarked).map(mark),
            // Somewhere you haven't been in years is a lovely thing to open on
            // and a list of four of them is a lot to scroll past, so they are
            // the hero some days and a row on none.
            revisits: [],
            mediaTypes: types,
            recentlyDeleted: deleted,
            recentlyAdded: arrived,
            favorites: marked,
            allTrips: trips.map(mark),
            allOccasions: occasions.map { mark(yearMarked($0.summary)) },
            featured: featured.map(mark),
            traditions: Self.withTrips(traditions, trips: everyTrip, today: today, turn: turn)
                .map { Self.withPeople($0, people: whoIsWho) },
            wideTrips: Self.featuredTrips(
                unfeaturedTrips, today: today, heroPlace: hero.flatMap(Self.place(of:)),
                limit: Self.wideLimit
            ).map(mark),
            // What happened once: the years of a tradition are its card's.
            wideDays: Self.featuredOccasions(
                unfeaturedOccasions.filter { yearMarked($0.summary).tradition == nil },
                today: today, comingUp: comingUp, heroOccasion: heroOccasion,
                limit: Self.wideLimit
            ).map(mark),
            // No Together: two people's album was one section too many on a
            // page that already had a lot going on (his call, 2026-11-09).
            // People's names go into the albums the page already has.
            people: people
        )
    }

    // MARK: - Named for the people in it

    /// One person the owner named, in one day's photos.
    struct Presence {
        let personID: UUID
        let name: String
        let relation: String?
        let isMe: Bool
        let photos: Int
    }

    /// Who the owner named, for the page's titles: day by day, with the day
    /// each was first photographed and the day the library begins, which
    /// together say how old a child turned.
    struct NamedPeople {
        var byDay: [String: [Presence]] = [:]
        var firstDay: [UUID: String] = [:]
        var libraryFirstDay: String?
        /// Whose birthday each birthday party was, by day. See
        /// `whoseBirthday`.
        var birthdays: [String: Presence] = [:]
        /// The parties whose cake was photographed with people the owner
        /// named, in two photos at least: there, the cake says whose it was,
        /// or that it isn't plain, and nothing else is asked.
        var cakeDays: Set<String> = []
        /// What's written in each party's photos of the cake, by day: the
        /// numbers the owner's devices read in each. See `writtenAge`.
        var writing: [String: [CakeWriting]] = [:]
        var isEmpty: Bool { byDay.isEmpty }

        func sawTheCake(on days: [String]) -> Bool { days.contains(where: cakeDays.contains) }

        /// Whose birthday it was, on any of these days.
        func birthday(on days: [String]) -> Presence? {
            days.lazy.compactMap { birthdays[$0] }.first
        }
    }

    /// One photo of a birthday's cake that has numbers written in it.
    struct CakeWriting {
        let numbers: Set<Int>
        /// Who the owner named in it.
        let people: Set<UUID>
    }

    static func namedPeople(
        spaceID: UUID, userID: UUID, scope: EventScope = EventScope(), on sql: any SQLDatabase
    ) async throws -> NamedPeople {
        struct Row: Decodable {
            let day: String
            let personID: UUID
            let name: String
            let relation: String?
            let isMe: Bool
            let photos: Int
        }
        let rows = try await sql.raw("""
            SELECT to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD') AS day,
                   p.id AS "personID", p.name, p.relation, p.is_me AS "isMe",
                   count(DISTINCT a.sha256)::int AS photos
            FROM person_faces pf
            JOIN people p ON p.id = pf.person_id AND p.name IS NOT NULL AND NOT p.hidden
            JOIN assets a ON a.sha256 = pf.sha256
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                AND sa.deleted_at IS NULL
            WHERE pf.user_id = \(bind: userID) AND pf.state IN ('auto', 'confirmed')
              AND \(unsafeRaw: TimelineController.visible)
              \(scope.filter)
            GROUP BY 1, p.id, p.name, p.relation, p.is_me
            """).all(decoding: Row.self)
        guard !rows.isEmpty else { return NamedPeople() }
        struct First: Decodable { let day: String? }
        let library = try await sql.raw("""
            SELECT to_char(min(\(unsafeRaw: TimelineController.localTime)), 'YYYY-MM-DD') AS day
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
            """).first(decoding: First.self)
        var people = NamedPeople()
        people.libraryFirstDay = library?.day
        for row in rows {
            people.byDay[row.day, default: []].append(Presence(
                personID: row.personID, name: row.name, relation: row.relation, isMe: row.isMe, photos: row.photos
            ))
            if row.day < people.firstDay[row.personID, default: "9999"] { people.firstDay[row.personID] = row.day }
        }
        (people.birthdays, people.cakeDays, people.writing) = try await birthdayPeople(
            userID: userID, scope: scope, on: sql
        )
        return people
    }

    /// Someone in the photos that show a birthday's cake.
    struct CakeSeat {
        let personID: UUID
        let name: String
        let relation: String?
        let isMe: Bool
        var photos = 0
        /// Their share of the faces in those photos, by area, added up: the
        /// one the photos are taken of is nearest the camera.
        var prominence = 0.0
    }

    /// Whose birthday each birthday party was: the person at the cake, from
    /// the faces in the photos that show it (see `whoseBirthday`). And what
    /// those photos have written in them, for how old they turned (see
    /// `writtenAge`).
    static func birthdayPeople(
        userID: UUID, scope: EventScope, on sql: any SQLDatabase
    ) async throws -> (whose: [String: Presence], seen: Set<String>, writing: [String: [CakeWriting]]) {
        let cakes = scope.showing.filter { scope.tags[$0.key] == "birthday" }
        let files = Array(Set(cakes.values.joined()))
        guard !files.isEmpty else { return ([:], [], [:]) }
        struct Face: Decodable {
            let sha256: String
            let personID: UUID
            let name: String
            let relation: String?
            let isMe: Bool
            let box: [Float]
        }
        let faces = try await sql.raw("""
            SELECT pf.sha256, p.id AS "personID", p.name, p.relation, p.is_me AS "isMe", pf.box
            FROM person_faces pf
            JOIN people p ON p.id = pf.person_id AND p.name IS NOT NULL AND NOT p.hidden
            WHERE pf.user_id = \(bind: userID) AND pf.state IN ('auto', 'confirmed')
              AND pf.sha256 = ANY(\(bind: files)::text[])
            """).all(decoding: Face.self)
        let byFile = Dictionary(grouping: faces, by: \.sha256)
        // The numbers the owner's phone read in them: whole numbers from 1 to
        // 18, never the writing (`PhotoAnalyzer.readNumbers`).
        struct Written: Decodable { let sha256: String; let written: [Int] }
        let written = try await sql.raw("""
            SELECT sha256, written::int8[] AS written
            FROM media_observations
            WHERE user_id = \(bind: userID) AND sha256 = ANY(\(bind: files)::text[])
              AND cardinality(written) > 0
            """).all(decoding: Written.self)
        let numbers = Dictionary(written.map { ($0.sha256, Set($0.written)) }, uniquingKeysWith: { a, _ in a })
        var writing: [String: [CakeWriting]] = [:]
        var found: [String: Presence] = [:]
        var seen = Set<String>()
        for (day, files) in cakes {
            let read = files.compactMap { file in
                numbers[file].map { CakeWriting(numbers: $0, people: Set((byFile[file] ?? []).map(\.personID))) }
            }
            if !read.isEmpty { writing[day] = read }
            var seats: [UUID: CakeSeat] = [:]
            var photos = 0
            for file in files {
                guard let here = byFile[file], !here.isEmpty else { continue }
                photos += 1
                // Each person once a photo, by their largest face in it.
                var largest: [UUID: (face: Face, area: Double)] = [:]
                for face in here {
                    let area = face.box.count == 4 ? Double(max(0, face.box[2]) * max(0, face.box[3])) : 0
                    if area >= largest[face.personID]?.area ?? -1 { largest[face.personID] = (face, area) }
                }
                let total = largest.values.reduce(0) { $0 + $1.area }
                for (id, seen) in largest {
                    var seat = seats[id] ?? CakeSeat(
                        personID: id, name: seen.face.name, relation: seen.face.relation, isMe: seen.face.isMe
                    )
                    seat.photos += 1
                    seat.prominence += total > 0 ? seen.area / total : 1 / Double(largest.count)
                    seats[id] = seat
                }
            }
            if photos >= 2 { seen.insert(day) }
            found[day] = whoseBirthday(Array(seats.values), photos: photos)
        }
        return (found, seen, writing)
    }

    /// Whose birthday it was, from the photos of the cake: whoever is in the
    /// most of them, and in two at least and half of those with anyone named
    /// in them. A child of the family in nearly as many wins over an adult,
    /// since a child's parents are at their cake too. Nil where it isn't
    /// plain, such as twins, and for the owner's own.
    static func whoseBirthday(_ seats: [CakeSeat], photos: Int) -> Presence? {
        let regulars = seats
            .filter { $0.photos >= 2 && $0.photos * 2 >= photos }
            .sorted {
                ($0.photos, $0.prominence, $1.name, $1.personID.uuidString)
                    > ($1.photos, $1.prominence, $0.name, $0.personID.uuidString)
            }
        guard let top = regulars.first else { return nil }
        var pick = top
        if !isChildLike(top.relation),
           let child = regulars.first(where: {
               isChildLike($0.relation) && ($0.photos + 1 >= top.photos || $0.photos * 5 >= top.photos * 4)
           }) {
            pick = child
        }
        // Plain: no one else of their kind is in as many, as near the camera.
        if let rival = regulars.first(where: {
            $0.personID != pick.personID && isChildLike($0.relation) == isChildLike(pick.relation)
        }), rival.photos >= pick.photos, rival.prominence * 1.25 > pick.prominence {
            return nil
        }
        guard !pick.isMe else { return nil }
        return Presence(
            personID: pick.personID, name: pick.name, relation: pick.relation, isMe: false, photos: pick.photos
        )
    }

    /// One person across a card's days, the most photographed first.
    struct Presences {
        let ranked: [Presence]

        init(_ people: NamedPeople, days: [String]) {
            var total: [UUID: Presence] = [:]
            for day in days {
                for seen in people.byDay[day] ?? [] {
                    let photos = (total[seen.personID]?.photos ?? 0) + seen.photos
                    total[seen.personID] = Presence(
                        personID: seen.personID, name: seen.name, relation: seen.relation,
                        isMe: seen.isMe, photos: photos
                    )
                }
            }
            ranked = total.values.sorted {
                $0.photos != $1.photos ? $0.photos > $1.photos
                    : ($0.name, $0.personID.uuidString) < ($1.name, $1.personID.uuidString)
            }
        }

        /// Who the photos are of, where one person plainly is: in at least
        /// three and half of them, and twice as many as anyone else. Never
        /// the owner: their photos are of everyone else.
        func focus(of count: Int) -> Presence? {
            let others = ranked.filter { !$0.isMe }
            guard let first = others.first, first.photos >= 3, first.photos * 2 >= count,
                  first.photos >= 2 * (others.dropFirst().first?.photos ?? 0)
            else { return nil }
            return first
        }

        /// What a family gathering is called after the people at it: the
        /// last name most of them share ("Deem"), or "Family" for three or
        /// more of the owner's family. Nil when neither is plain.
        var familyWord: String? {
            let there = ranked.filter { $0.photos >= 2 }
            let surnames = Dictionary(grouping: there.compactMap { CollectionsController.surname($0.name) }, by: { $0 })
            if let shared = surnames.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
               shared.value.count >= 2, shared.value.count * 2 >= there.count {
                return shared.key
            }
            let family = there.filter { $0.isMe || Relationship(rawValue: $0.relation ?? "")?.isFamily == true }
            return family.count >= 3 ? "Family" : nil
        }
    }

    /// The holidays a family gathers for, which a family's name suits:
    /// "Deem Christmas 2023", "Family Thanksgiving 2024".
    static let gatheringHolidays: Set<String> = [
        "Christmas", "Christmas Eve", "Christmas Day", "Thanksgiving", "Easter", "Fourth of July",
    ]

    /// Games that are somebody's: whoever the photos are of was playing.
    static let games: [String: String] = [
        "soccer": "Soccer Game", "baseball": "Baseball Game", "softball": "Softball Game",
        "basketball": "Basketball Game", "football": "Football Game", "volleyball": "Volleyball Game",
        "hockey": "Hockey Game", "tennis": "Tennis Match", "gymnastics": "Gymnastics Meet",
        "sports": "Game Day",
    ]

    /// A trip or an occasion, named for the people in it where it plainly
    /// fits, and never wordy:
    /// - a birthday party plainly someone's: "Celebrating Thomas's 2nd
    ///   Birthday", or "Thomas's Birthday" when his age isn't plain;
    /// - a graduation or a game: "Emma's Graduation", "Jack's Soccer Game";
    /// - a family holiday: "Deem Christmas 2023", "Family Thanksgiving 2024";
    ///   Halloween plainly one child's: "Thomas's Halloween 2023".
    ///
    /// Otherwise one or two people who are the focus go under the title:
    /// "with Thomas", "with Thomas and Grandma". Never a list of everyone.
    /// A name the owner gave the album is never changed.
    static func withPeople(
        _ card: CollectionSummary, people: NamedPeople, occasion: Occasion?
    ) -> CollectionSummary {
        guard !people.isEmpty, [.trip, .day, .anniversary].contains(card.kind) else { return card }
        let days = days(inKey: card.key)
        let there = Presences(people, days: days)
        guard !there.ranked.isEmpty else { return card }

        if !card.isNamed, card.kind == .day, let occasion, let name = occasion.occasion,
           let renamed = retitled(card, occasion: name, isEvent: occasion.isEvent,
                                  isHoliday: occasion.isHoliday, there: there, people: people, days: days) {
            return renamed
        }

        // One or two people the photos are of, each in a third of them.
        let focus = there.ranked.filter { !$0.isMe && $0.photos >= 2 && $0.photos * 3 >= card.count }
        var names: [String] = []
        for person in focus where !names.contains(firstName(person.name)) { names.append(firstName(person.name)) }
        guard (1...2).contains(names.count) else { return card }
        let phrase = names.count == 1 ? "with \(names[0])" : "with \(names[0]) and \(names[1])"
        return card.withSubtitle([card.subtitle, phrase].compactMap { $0 }.joined(separator: " · "))
    }

    /// An occasion card under a title that says whose it was, or nil.
    static func retitled(
        _ card: CollectionSummary, occasion: String, isEvent: Bool, isHoliday: Bool,
        there: Presences, people: NamedPeople, days: [String]
    ) -> CollectionSummary? {
        if isEvent, let event = CurationVocabulary.events.first(where: { $0.title == occasion }) {
            // A birthday is whoever's at the cake, where the cake was
            // photographed with people the owner named; anything else,
            // whoever the photos are of.
            let cake = event.tag == "birthday" && people.sawTheCake(on: days)
            guard let focus = cake ? people.birthday(on: days) : there.focus(of: card.count) else { return nil }
            let first = firstName(focus.name)
            let title: String
            switch event.tag {
            case "birthday":
                title = birthdayTitle(first, age: turned(focus, on: days, people: people))
            case "graduation":
                title = "\(first)'s Graduation"
            default:
                guard let game = games[event.tag] else { return nil }
                title = "\(first)'s \(game)"
            }
            return moved(card, to: title, from: event.title)
        }
        if isHoliday, card.title.hasPrefix(occasion) {
            if gatheringHolidays.contains(occasion), let family = there.familyWord {
                return card.withTitle("\(family) \(card.title)")
            }
            if occasion == "Halloween", let focus = there.focus(of: card.count), isChildLike(focus.relation) {
                return card.withTitle("\(firstName(focus.name))'s \(card.title)")
            }
        }
        return nil
    }

    /// "Celebrating Thomas's 2nd Birthday", or "Thomas's Birthday".
    static func birthdayTitle(_ first: String, age: Int?) -> String {
        age.map { "Celebrating \(first)'s \(ordinal($0)) Birthday" } ?? "\(first)'s Birthday"
    }

    /// The card under its new title, with the place its old title carried
    /// ("Birthday party in Culpeper") moved to the line under it.
    static func moved(_ card: CollectionSummary, to title: String, from phrase: String) -> CollectionSummary {
        var renamed = card.withTitle(title)
        let rest = card.title.hasPrefix(phrase) ? card.title.dropFirst(phrase.count) : ""
        let words = rest.split(separator: " ", maxSplits: 1)
        if words.count == 2, ["in", "at", "to"].contains(words[0]) {
            var parts = (card.subtitle ?? "").components(separatedBy: " · ").filter { !$0.isEmpty }
            parts.insert(String(words[1]), at: min(1, parts.count))
            renamed = renamed.withSubtitle(parts.joined(separator: " · "))
        }
        return renamed
    }

    /// How old a child of the family turned at their party on `days`: what's
    /// written on the cake, where two photos of it say so, since that's the
    /// family's own word and wins over anything worked out (decided
    /// 2026-11-10); otherwise how long since they first appeared. Never for
    /// a parent, a friend or the owner.
    static func turned(_ person: Presence, on days: [String], people: NamedPeople) -> Int? {
        guard !person.isMe, isChildLike(person.relation) else { return nil }
        return writtenAge(of: person, on: days, people: people)
            ?? days.last.flatMap { age(of: person, on: $0, people: people) }
    }

    /// The age written in the photos of a party's cake: a "2" candle, "Happy
    /// 2nd Birthday", a "TWO" banner (`PhotoAnalyzer.readNumbers`).
    ///
    /// Counted over the photos of the cake that show them, or show no one the
    /// owner named, so a sibling's cake at the same party doesn't count. The
    /// number has to be in two of those at least, and in more of them than
    /// any other number. One photo alone never decides it.
    ///
    /// Never younger than they've been in the library: a cousin in the photos
    /// since 2019 isn't turning 1 in 2026, whatever a candle looked like. And
    /// never a 4 on the Fourth of July, the day's own "Happy 4th".
    static func writtenAge(of person: Presence, on days: [String], people: NamedPeople) -> Int? {
        var photos: [Int: Int] = [:]
        for day in days {
            for photo in people.writing[day] ?? []
            where photo.people.isEmpty || photo.people.contains(person.personID) {
                for number in photo.numbers where !(number == 4 && day.hasSuffix("-07-04")) {
                    photos[number, default: 0] += 1
                }
            }
        }
        let ranked = photos.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        guard let top = ranked.first, top.value >= 2,
              ranked.count == 1 || ranked[1].value < top.value
        else { return nil }
        if let first = people.firstDay[person.personID].flatMap(CivilDay.number),
           let party = days.last.flatMap(CivilDay.number),
           Double(top.key) < (Double(party - first) / 365.2425).rounded(.down) {
            return nil
        }
        return top.key
    }

    /// How old a child turned on `day`, where it's plain: a child, grandchild,
    /// niece, nephew or cousin of the owner, first photographed at least two
    /// months into the library, which is when they arrived, and a whole number
    /// of years from then to within three weeks.
    static func age(of person: Presence, on day: String, people: NamedPeople) -> Int? {
        guard !person.isMe, let relation = person.relation, isChildLike(relation),
              let first = people.firstDay[person.personID].flatMap(CivilDay.number),
              let start = people.libraryFirstDay.flatMap(CivilDay.number),
              let party = CivilDay.number(day), first - start >= 60
        else { return nil }
        let days = Double(party - first)
        let years = (days / 365.2425).rounded()
        guard (1...18).contains(Int(years)), abs(days - years * 365.2425) <= 21 else { return nil }
        return Int(years)
    }

    /// A child of the family's, by what the owner said they are.
    static func isChildLike(_ relation: String?) -> Bool {
        guard let kind = relation.flatMap(Relationship.init(rawValue:))?.kind else { return false }
        return [.child, .grandchild, .nieceOrNephew, .cousin].contains(kind)
    }

    /// "Thomas" from "Thomas Deem", "Grandma" from "Grandma Deem".
    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// The family name in a name, when it has one: "Deem" from "Thomas Deem".
    static func surname(_ name: String) -> String? {
        var words = name.split(separator: " ").map(String.init)
        if let last = words.last, ["Jr", "Jr.", "Sr", "Sr.", "II", "III", "IV"].contains(last) { words.removeLast() }
        guard words.count >= 2, let last = words.last, last.count >= 2,
              last.first?.isUppercase == true,
              last.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" })
        else { return nil }
        return last
    }

    /// 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st.
    static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 100, number % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }

    /// Over the Years, named the same way: a birthday that's plainly the same
    /// child's every year becomes "Thomas's Birthday", each year "Celebrating
    /// Thomas's 2nd Birthday"; a family holiday's years take the family's
    /// name where it fits. A name the owner gave is never touched.
    static func withPeople(_ tradition: Tradition, people: NamedPeople) -> Tradition {
        guard !people.isEmpty else { return tradition }
        let birthday = CurationVocabulary.events.first { $0.tag == "birthday" }?.title ?? "Birthday party"
        if tradition.title.hasPrefix("Birthday on ") || tradition.title.hasPrefix(birthday) {
            let whose = tradition.years.map { year in
                let days = days(inKey: year.key)
                return (year, people.sawTheCake(on: days)
                    ? people.birthday(on: days) : Presences(people, days: days).focus(of: year.count))
            }
            let found = Set(whose.compactMap { $0.1?.personID })
            guard found.count == 1, whose.filter({ $0.1 != nil }).count >= 2,
                  let person = whose.compactMap(\.1).first
            else { return tradition }
            let first = firstName(person.name)
            let years = whose.map { year, focus -> CollectionSummary in
                let inYear = days(inKey: year.key)
                guard let focus, let day = inYear.last else { return year }
                let title = turned(focus, on: inYear, people: people)
                    .map { birthdayTitle(first, age: $0) } ?? "\(first)'s Birthday \(day.prefix(4))"
                return year.withTitle(title)
            }
            return Tradition(
                id: tradition.id, title: "\(first)'s Birthday", subtitle: tradition.subtitle,
                count: tradition.count, coverAssetIDs: tradition.coverAssetIDs, years: years,
                next: tradition.next, naming: tradition.naming
            )
        }
        if tradition.id.hasPrefix("holiday:") {
            let holiday = String(tradition.id.dropFirst("holiday:".count))
            guard gatheringHolidays.contains(holiday) else { return tradition }
            let years = tradition.years.map { year -> CollectionSummary in
                guard year.title.hasPrefix(holiday),
                      let family = Presences(people, days: days(inKey: year.key)).familyWord
                else { return year }
                return year.withTitle("\(family) \(year.title)")
            }
            return Tradition(
                id: tradition.id, title: tradition.title, subtitle: tradition.subtitle,
                count: tradition.count, coverAssetIDs: tradition.coverAssetIDs, years: years,
                next: tradition.next, naming: tradition.naming
            )
        }
        return tradition
    }

    /// At most this many cards to swipe through at the top of the page.
    static let featuredLimit = 6

    /// The top row's cards in order: today's, then the highlights with a
    /// featured photo after the first and the third, so photos and places
    /// alternate rather than bunching. Each set of photos once: an
    /// anniversary is a trip wearing a different sentence, and the same trip
    /// twice in one row is one card too many.
    static func featuredRow(
        today: [CollectionSummary], highlights: [CollectionSummary], photos: [CollectionSummary]
    ) -> [CollectionSummary] {
        var rest: [CollectionSummary] = []
        var waiting = photos[...]
        for (index, card) in highlights.enumerated() {
            rest.append(card)
            if index % 2 == 0, let photo = waiting.popFirst() { rest.append(photo) }
        }
        rest += waiting

        var seen = Set<String>()
        return (today + rest)
            .filter { seen.insert($0.key).inserted }
            .prefix(featuredLimit)
            .map { $0 }
    }

    /// `items` begun at `turn`, wrapping round, so each day starts with a
    /// different one.
    static func rotated<Item>(_ items: [Item], by turn: Int) -> [Item] {
        guard !items.isEmpty else { return [] }
        let start = turn % items.count
        return Array(items[start...] + items[..<start])
    }

    /// Two of the library's best-looking photos, as Photos features its own:
    /// rated well by the person's own phone, never a screenshot or a receipt,
    /// at least a month old so they're a rediscovery rather than a rerun of
    /// the camera roll, from two different days, and a different pair each
    /// day. Each opens the day it was taken.
    ///
    /// Only where the person's devices have analyzed the library; without
    /// their ratings, "featured" would only mean "random".
    private func featuredPhotos(
        spaceID: UUID, userID: UUID, today: Date, seed: String, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        struct PhotoRow: Decodable {
            let id: UUID
            let day: String
            let place: String?
        }
        struct CountRow: Decodable {
            let day: String
            let count: Int
        }
        guard let cutoff = Self.utc.date(byAdding: .day, value: -30, to: today) else { return [] }
        let local = TimelineController.localTime
        let candidates = try await sql.raw("""
            SELECT a.id, to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                   \(unsafeRaw: TimelineController.placeName) AS place
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN media_observations o ON o.user_id = \(bind: userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND a.media_type = 'photo' AND a.derived_at IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND NOT COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false)
              AND COALESCE(o.aesthetic, 0) > \(bind: Self.goodLooking)
              AND to_char(\(unsafeRaw: local), 'YYYY-MM-DD') < \(bind: Self.dayStamp(cutoff))
            ORDER BY md5(a.id::text || \(bind: seed))
            LIMIT 12
            """).all(decoding: PhotoRow.self)

        var days = Set<String>()
        let picked = candidates.filter { days.insert($0.day).inserted }.prefix(2)
        guard !picked.isEmpty else { return [] }

        let counts = try await sql.raw("""
            SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day, count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND to_char(\(unsafeRaw: local), 'YYYY-MM-DD') = ANY(\(bind: picked.map(\.day))::text[])
            GROUP BY 1
            """).all(decoding: CountRow.self)
        let byDay = Dictionary(counts.map { ($0.day, $0.count) }, uniquingKeysWith: { first, _ in first })

        return picked.map { photo in
            let date = Self.longDay(photo.day) ?? photo.day
            return CollectionSummary(
                kind: .day, key: photo.day,
                title: photo.place ?? date,
                subtitle: photo.place == nil ? nil : date,
                count: byDay[photo.day] ?? 1,
                coverAssetIDs: [photo.id],
                kicker: "FEATURED PHOTO"
            )
        }
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
        _ trips: [CollectionSummary], today: Date, heroPlace: String?, limit: Int = pageTrips
    ) -> [CollectionSummary] {
        let ranked = trips.sorted { a, b in
            let (wa, wb) = (weight(a, today: today), weight(b, today: today))
            return wa != wb ? wa > wb : a.key > b.key
        }
        var places = Set(heroPlace.map { [$0] } ?? [])
        var chosen: [CollectionSummary] = []
        for trip in ranked where chosen.count < limit {
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
        comingUp: CollectionSummary?, heroOccasion: String?, limit: Int = pageOccasions
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
        for candidate in ranked where chosen.count < limit {
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
    /// ten years ago, but gently: two weeks in Maine are still worth offering
    /// three years on, where a hard cutoff at a year would drop them for a
    /// four-photo afternoon.
    static func weight(_ collection: CollectionSummary, today: Date) -> Double {
        let age = start(of: collection).map { today.timeIntervalSince($0) / (365.25 * 86_400) } ?? 10
        return Double(collection.count) / (1 + max(age, 0))
    }

    /// Where a card is — "Nags Head" from "Six days in Nags Head", or from
    /// "Beach trip to Nags Head", and "Walt Disney World" from "Four days at
    /// Walt Disney World" — for keeping one card per place. Nil for cards that
    /// aren't anywhere in particular.
    static func place(of collection: CollectionSummary) -> String? {
        switch collection.kind {
        case .trip:
            return tripPlace(inTitle: collection.title)
        case .anniversary:
            // "the Outer Banks" from its sentence, as a trip's name says it:
            // "OBX".
            return whereabouts(inTitle: collection.title).map {
                Destinations.place(spoken: $0.place)?.title ?? Whereabouts(name: $0.place).title
            }
        case .revisit:
            return collection.title
        default:
            return nil
        }
    }

    /// The place a trip's title names and the word before it: ("at", "Walt
    /// Disney World") from "Four days at Walt Disney World". The first of them
    /// in the title, since what comes before it is a length, a holiday or a
    /// kind of trip, and none of those has one.
    static func whereabouts(inTitle title: String) -> (preposition: String, place: String)? {
        let found = [" in ", " at ", " on ", " to "]
            .compactMap { title.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let found else { return nil }
        return (
            title[found].trimmingCharacters(in: .whitespaces),
            String(title[found.upperBound...])
        )
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
        //
        // Holidays and named days only. Last year's soccer game was an event,
        // not something that comes round again.
        var best: (date: Date, summary: CollectionSummary)?
        for candidate in occasions where candidate.occasion != nil && !candidate.isEvent {
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
            \(Self.observed(by: userID))
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
        /// Everywhere this day went, not just where most of it was, by the
        /// names the places go by (`TimelineController.placeName`).
        ///
        /// The daily mode was the first attempt and it quietly lost the point:
        /// a week moving between Nags Head, Kill Devil Hills and Duck every day
        /// collapsed each day to one of them, and the trip ended up named after
        /// whichever won a tie — "Seven days in Duck" for a vacation that was
        /// nothing of the sort.
        let places: [String]
        /// How many of the day's photos each of `places` holds, in the same
        /// order.
        let placeCounts: [Int]
        /// Where each of `places` was that day: the middle of its photos.
        let placeLatitudes: [Double]
        let placeLongitudes: [Double]
        /// Where the library has most of its photos, so a trip can tell it
        /// went abroad.
        let home: String?
        let coverAssetIDs: [UUID]
        /// Minutes with photos in them. See `DayRow.moments`. Optional, so a
        /// query that doesn't select it still decodes.
        var moments: Int?
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
    /// radius of a life. Work, school, the stores and the next town over are all
    /// "not home" and none of them are trips, and a threshold that called them
    /// trips would bury two weeks on the Outer Banks under two hundred
    /// commutes.
    ///
    /// A single day that far away is a day out, not a trip, so a run has to
    /// span at least two.
    private func trips(
        spaceID: UUID, seed: String, userID: UUID, holidays: [String: String],
        evidence: [String: DayEvidence] = [:], geocoder: Geocoder? = nil,
        on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let local = TimelineController.localTime
        let rows = try await sql.raw("""
            WITH located AS (
                SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                       date_trunc('minute', \(unsafeRaw: local)) AS minute,
                       a.lat, a.lon, \(unsafeRaw: TimelineController.placeName) AS place_name,
                       a.id, a.derived_at, a.camera_make,
                       a.burst_id, a.burst_pick, a.media_type,
                       -- For the covers below; see `coverOrder`.
                       COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false) AS utility,
                       COALESCE(o.aesthetic, 0) AS aesthetic
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                \(Self.observed(by: userID))
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
            -- Each photo, and whether it was taken away. A day is away when
            -- most of its photos were, never by where they average out: the
            -- cat at home and a few photos from somewhere far averaged to a
            -- town nobody was in, and five days of that were "Trip 2022" (his
            -- library, 2026-11-10).
            marked AS (
                SELECT l.*,
                       6371 * acos(LEAST(1, GREATEST(-1,
                           sin(radians(l.lat)) * sin(radians(h.lat))
                         + cos(radians(l.lat)) * cos(radians(h.lat))
                         * cos(radians(l.lon - h.lon))
                       ))) > \(bind: Self.awayKilometers) AS far
                FROM located l CROSS JOIN home h
                WHERE h.lat IS NOT NULL
            ),
            -- Places worth naming the day after: ones holding at least a fifth
            -- of it. A trip picks up stray coordinates — the drive home, a
            -- screenshot, someone else's phone with a stale fix — and a single
            -- outlier should not be able to turn "Four days in Asheville" into
            -- "Four days away" by making the town count look like two.
            --
            -- Each with how many photos it holds and where they were, so the
            -- title can tell the place most of a trip was spent from one it
            -- passed through, and which area a place is in. See
            -- `whereabouts(of:)`.
            -- Of the photos taken away only: home on the morning you left is
            -- not where the trip was.
            per_place AS (
                SELECT day, place_name, count(*)::int AS n,
                       avg(lat) AS lat, avg(lon) AS lon
                FROM marked WHERE place_name IS NOT NULL AND far
                GROUP BY day, place_name
            ),
            day_total AS (
                SELECT day, sum(n)::int AS total FROM per_place GROUP BY day
            ),
            main_places AS (
                SELECT p.day,
                       ARRAY_AGG(p.place_name ORDER BY p.n DESC, p.place_name) AS places,
                       ARRAY_AGG(p.n::bigint ORDER BY p.n DESC, p.place_name) AS counts,
                       ARRAY_AGG(p.lat ORDER BY p.n DESC, p.place_name) AS lats,
                       ARRAY_AGG(p.lon ORDER BY p.n DESC, p.place_name) AS lons
                FROM per_place p JOIN day_total d ON d.day = p.day
                WHERE p.n * 5 >= d.total
                GROUP BY p.day
            ),
            per_day AS (
                SELECT day,
                       count(*)::int AS count,
                       count(*) FILTER (WHERE far)::int AS away,
                       count(DISTINCT minute) FILTER (WHERE far)::int AS moments,
                       (ARRAY_AGG(id ORDER BY
                            far DESC,
                            (derived_at IS NOT NULL) DESC,
                            utility ASC,
                            (aesthetic > \(unsafeRaw: String(Self.goodLooking))) DESC,
                            (camera_make IS NOT NULL) DESC,
                            (burst_id IS NULL OR burst_pick) DESC,
                            (media_type = 'photo') DESC,
                            md5(id::text || '\(unsafeRaw: seed)')
                        )) [1:\(unsafeRaw: String(Self.coverDepth))] AS cover
                FROM marked GROUP BY day
            )
            SELECT p.day, p.count,
                   COALESCE(m.places, ARRAY[]::text[]) AS places,
                   COALESCE(m.counts, ARRAY[]::bigint[]) AS "placeCounts",
                   COALESCE(m.lats, ARRAY[]::float8[]) AS "placeLatitudes",
                   COALESCE(m.lons, ARRAY[]::float8[]) AS "placeLongitudes",
                   (SELECT place_name FROM busiest) AS home,
                   p.cover AS "coverAssetIDs", p.moments
            FROM per_day p
            LEFT JOIN main_places m ON m.day = p.day
            WHERE p.away * 2 > p.count
            ORDER BY p.day DESC
            LIMIT 1000
            """).all(decoding: TripDay.self)

        // A thousand days away rather than four hundred, now that See All
        // reaches further back than the page does. Day trips count against it
        // too, and a family that drives to the coast most weekends used those
        // up within a couple of years.
        // And a trip is somewhere: days away that no place holds most of are
        // photos from all over, not a trip anyone took. Unless there are days
        // and days of them, which is a road trip.
        return Self.tripRuns(from: rows)
            .filter { run in
                let moments = run.reduce(0) { $0 + ($1.moments ?? $1.count) }
                guard run.count >= 2, run.reduce(0, { $0 + $1.count }) >= Self.minimumItems,
                      moments >= Self.tripMoments else { return false }
                return Self.whereabouts(of: run, geocoder: geocoder) != nil
                    || (run.count >= Self.roadTripDays && moments >= Self.roadTripMoments)
            }
            .map {
                Self.describeTrip(
                    $0, holidays: holidays,
                    event: Self.tripEvent(days: $0.map(\.day), evidence: evidence),
                    geocoder: geocoder
                )
            }
    }

    /// How far from home stops being an errand.
    static let awayKilometers = 80
    /// A trip no one place holds most of is a road trip only with this many
    /// days and moments in it; less is photos from all over.
    static let roadTripDays = 3
    static let roadTripMoments = 18

    /// Groups consecutive days into trips. Rows arrive newest-first.
    ///
    /// A single missing day doesn't end a trip — there are days on any vacation
    /// when nobody takes a photograph, and splitting two weeks away into two
    /// trips because of one rainy Tuesday would be worse than useless.
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

    /// What the family calls the trip, as they'd name the album themselves:
    /// where, what kind of stay, and the year. "OBX Beach Week 2025", "WDW
    /// Vacation 2025", "Asheville Weekend 2024", "Italy Vacation 2024".
    /// Never how long it was: nobody says "seven days in the Outer Banks"
    /// (his word, 2026-11-10), and the dates under the title say it anyway.
    /// Where is as particular as is true (see `whereabouts(of:)`), by the
    /// name a family uses for it (`Destinations.Place.nickname`).
    ///
    /// A week or less away over a holiday is named for the holiday — "Christmas
    /// 2024 in Asheville" is what the family calls it, and the days it covers
    /// are claimed by the trip, so it is the only card that can say so. Two
    /// weeks away that happen to include Labor Day were not a Labor Day trip.
    static func describeTrip(
        _ run: [TripDay], holidays: [String: String] = [:],
        event: CurationVocabulary.Event? = nil, geocoder: Geocoder? = nil
    ) -> CollectionSummary {
        let ordered = run.reversed().map { $0 }        // oldest first
        let count = run.reduce(0) { $0 + $1.count }
        let where_ = whereabouts(of: run, geocoder: geocoder)

        let weekdays = ordered.compactMap { parseDate($0.day) }
            .map { utc.component(.weekday, from: $0) }
        let weekend = (run.count == 2 && weekdays.contains(1) && weekdays.contains(7))
            || (run.count == 3 && (weekdays.contains(1) || weekdays.contains(7)))

        let holiday = run.count <= 7
            ? run.filter { holidays[$0.day] != nil }
                .max { $0.count < $1.count }
                .flatMap { day in holidays[day.day].map { "\($0) \(day.day.prefix(4))" } }
            : nil

        let title: String
        if let holiday {
            title = where_.map { "\(holiday) \($0.locative)" } ?? "\(holiday) away from home"
        } else {
            var kind = tripKind(event: event, implies: where_?.implies ?? [], days: run.count, weekend: weekend)
            // Days on the road that no place holds most of.
            if where_ == nil { kind = "Road Trip" }
            let year = ordered.first.map { String($0.day.prefix(4)) } ?? ""
            title = [where_?.title, kind, year].compactMap { $0 }.joined(separator: " ")
        }

        var parts: [String] = []
        if let from = ordered.first.flatMap({ parseDate($0.day) }),
           let to = ordered.last.flatMap({ parseDate($0.day) }) {
            parts.append(dateRange(from: from, to: to))
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

    /// What kind of stay a trip was, as a family would say it: a week at
    /// the beach is "Beach Week" and a weekend there "Beach Weekend"; a
    /// theme park, a "Vacation"; a wedding, a "Wedding"; a week anywhere, a
    /// "Vacation"; a weekend, a "Weekend"; anything shorter, a "Trip". What
    /// the person's devices saw names it first, then what the place is.
    static func tripKind(
        event: CurationVocabulary.Event?, implies: Set<String>, days: Int, weekend: Bool
    ) -> String {
        let tag = event?.tag
        if tag == "wedding" { return "Wedding" }
        if tag == "graduation" { return "Graduation" }
        if tag == "beach" || implies.contains("beach") {
            return days >= 5 ? "Beach Week" : weekend ? "Beach Weekend" : "Beach Trip"
        }
        if implies.contains("snow") { return "Ski Trip" }
        if implies.contains("amusement_park") { return weekend ? "Weekend" : "Vacation" }
        if let tag, let kind = tripKinds[tag] { return kind }
        if days >= 5 { return "Vacation" }
        return weekend ? "Weekend" : "Trip"
    }

    /// The kinds of trip the photos can show, besides the beach.
    static let tripKinds: [String: String] = [
        "golf": "Golf Trip", "camping": "Camping Trip", "hiking": "Hiking Trip",
        "boating": "Boating Trip", "snow": "Snow Trip", "amusement_park": "Theme Park Trip",
        "fishing": "Fishing Trip",
    ]

    /// Every kind a trip's name can end in before its year, longest first, to
    /// read a name back. See `tripPlace(inTitle:)`.
    static let tripKindWords = [
        "Theme Park Trip", "Weekend Away", "Beach Weekend", "Fishing Trip", "Camping Trip",
        "Boating Trip", "Hiking Trip", "Beach Week", "Beach Trip", "Graduation", "Golf Trip",
        "Snow Trip", "Road Trip", "Ski Trip", "Vacation", "Wedding", "Weekend", "Trip",
    ]

    /// "OBX Beach Week" and 2025, from "OBX Beach Week 2025". Nil for a name
    /// that doesn't end in a year: a holiday's ("Christmas 2023 in
    /// Asheville") or one from before.
    static func yearless(_ title: String) -> (name: String, year: Int)? {
        guard let space = title.lastIndex(of: " "), let year = Int(title[title.index(after: space)...]),
              (1900...2999).contains(year) else { return nil }
        return (String(title[..<space]), year)
    }

    /// The place a trip's name says: "OBX" from "OBX Beach Week 2025". For a
    /// name from before, or a holiday's, the words after its preposition:
    /// "Walt Disney World" from "Four days at Walt Disney World".
    static func tripPlace(inTitle title: String) -> String? {
        if let (name, _) = yearless(title) {
            for kind in tripKindWords where name == kind || name.hasSuffix(" " + kind) {
                let place = name.dropLast(kind.count).trimmingCharacters(in: .whitespaces)
                return place.isEmpty ? nil : place
            }
        }
        return whereabouts(inTitle: title)?.place
    }

    /// Where a trip or a day was, as a title says it.
    struct Whereabouts {
        /// "Walt Disney World", "the Outer Banks", "Nags Head", "Florida".
        let name: String
        /// "at", "in" or "on".
        let preposition: String
        /// Trip kinds the name already says. See `Destinations.Place.implies`.
        var implies: Set<String> = []
        /// What a trip's name calls it: "OBX", "WDW", "Nags Head", "Italy".
        let title: String

        /// "at Walt Disney World".
        var locative: String { "\(preposition) \(name)" }

        /// "to the Outer Banks", for "Beach trip to the Outer Banks". Any
        /// other preposition means where it happened: "Wedding at Walt Disney
        /// World".
        func phrase(_ preposition: String) -> String {
            preposition == "to" ? "to \(name)" : locative
        }

        init(name: String, preposition: String = "in", implies: Set<String> = [], title: String? = nil) {
            self.name = name
            self.preposition = preposition
            self.implies = implies
            self.title = title ?? (name.hasPrefix("the ") ? String(name.dropFirst(4)) : name)
        }

        init(_ place: Destinations.Place) {
            self.init(name: place.spoken, preposition: place.preposition, implies: place.implies, title: place.title)
        }

        /// A stored place name as a title says it: a destination its own way,
        /// and a town by the town alone. "Culpeper, Virginia" is "in Culpeper".
        init(label: String) {
            if let place = Destinations.named(label: label) {
                self.init(place)
            } else {
                self.init(name: HeaderPlaces.town(label))
            }
        }

        /// How a title naming this place says being there: "at" for "Walt
        /// Disney World", from the list, and "in" for a town.
        static func locative(spoken: String) -> String {
            let preposition = Destinations.place(spoken: spoken)?.preposition ?? "in"
            return "\(preposition) \(spoken)"
        }
    }

    /// Where a trip was, as particularly as is true, or nil when it moved
    /// about too much to say.
    ///
    /// Tried from the most particular answer down, each by the share of the
    /// trip's photographs it holds:
    ///
    /// 1. A destination with half the photos, on at least half the days: "Six
    ///    days at Walt Disney World", hotel in Kissimmee and all. Both halves,
    ///    so one day at Epcot doesn't name two weeks in Tampa however many
    ///    photos it took.
    /// 2. A town with three quarters of them: "Six days in Asheville", the
    ///    drive down and all.
    /// 3. An area with three quarters of them, across its towns and
    ///    destinations: "Five days in Orlando" for Disney World, Universal and
    ///    the rental between them, and "Five days in the Smokies" for
    ///    Gatlinburg, Pigeon Forge and the park.
    /// 4. At home, a state with three quarters of them, "Ten days in Florida",
    ///    or two between them, "Ten days in Utah and Arizona". Abroad, the
    ///    country, "Ten days in Italy", or two, "in France and Italy", or the
    ///    continent of three or more, "in Europe": nobody calls a week in Rome
    ///    and Florence "Lazio and Tuscany". Except where a country's regions
    ///    are what people go to: Ontario, Scotland, Queensland.
    ///
    /// Three quarters where it used to be every one. A week in Nags Head with
    /// lunch in Virginia on the drive down was "Seven days away", and
    /// whichever town a trip's few strays landed in decided between a town
    /// and its state.
    ///
    /// Without the town dataset (`geocoder`) there are no countries to tell
    /// apart, and a trip abroad is named by its regions like one at home.
    static func whereabouts(of run: [TripDay], geocoder: Geocoder? = nil) -> Whereabouts? {
        struct Stay {
            var photos = 0
            var days = 0
            var latitude = 0.0
            var longitude = 0.0
            var located = 0.0
        }
        var stays: [String: Stay] = [:]
        for day in run {
            for (index, label) in day.places.enumerated() {
                let photos = index < day.placeCounts.count ? max(day.placeCounts[index], 1) : 1
                var stay = stays[label] ?? Stay()
                stay.photos += photos
                stay.days += 1
                if index < day.placeLatitudes.count, index < day.placeLongitudes.count {
                    stay.latitude += day.placeLatitudes[index] * Double(photos)
                    stay.longitude += day.placeLongitudes[index] * Double(photos)
                    stay.located += Double(photos)
                }
                stays[label] = stay
            }
        }
        let total = stays.values.reduce(0) { $0 + $1.photos }
        guard total > 0 else { return nil }
        let placedDays = run.filter { !$0.places.isEmpty }.count
        func most(_ photos: Int) -> Bool { photos * 4 >= total * 3 }
        // The alphabetically first of equals, so a title holds still between
        // two loads of the same page.
        func ranked(_ counts: [String: Int]) -> [(key: String, photos: Int)] {
            counts.map { ($0.key, $0.value) }
                .sorted { $0.photos != $1.photos ? $0.photos > $1.photos : $0.key < $1.key }
        }
        func biggest(_ counts: [String: Int]) -> (key: String, photos: Int)? { ranked(counts).first }
        // Two that hold most of it between them, each a real part of it.
        func pair(_ counts: [String: Int]) -> String? {
            let top = ranked(counts)
            guard top.count >= 2, most(top[0].photos + top[1].photos), top[1].photos * 4 >= total
            else { return nil }
            return "\(top[0].key) and \(top[1].key)"
        }

        var destinations: [String: Int] = [:]
        // By the town alone, so Niagara Falls on both sides of the border is
        // one place.
        var towns: [String: Int] = [:]
        var areas: [String: Int] = [:]
        var regions: [String: Int] = [:]
        var countries: [String: Int] = [:]
        for (label, stay) in stays {
            if Destinations.named(label: label) != nil {
                destinations[label] = stay.photos
            } else {
                towns[HeaderPlaces.town(label), default: 0] += stay.photos
            }
            if stay.located > 0 {
                let latitude = stay.latitude / stay.located
                let longitude = stay.longitude / stay.located
                for area in Destinations.areas(containing: latitude, longitude) {
                    areas[area.spoken, default: 0] += stay.photos
                }
            }
            if let region = label.split(separator: ",", maxSplits: 1).dropFirst().first?
                .trimmingCharacters(in: .whitespaces), !region.isEmpty {
                regions[region, default: 0] += stay.photos
            }
            if let country = geocoder?.country(ofLabel: label) {
                countries[country, default: 0] += stay.photos
            }
        }

        if let best = biggest(destinations), let place = Destinations.named(label: best.key),
           best.photos * 2 >= total, (stays[best.key]?.days ?? 0) * 2 >= placedDays {
            return Whereabouts(place)
        }
        if let best = biggest(towns), most(best.photos) {
            return Whereabouts(name: best.key)
        }
        if let best = biggest(areas), most(best.photos),
           let place = Destinations.place(spoken: best.key) {
            return Whereabouts(place)
        }

        let home = run.lazy.compactMap(\.home).first.flatMap { geocoder?.country(ofLabel: $0) }
        let country = biggest(countries)
        let abroad = home != nil && country != nil && country?.key != home
        if !abroad || Self.namedRegions.contains(country?.key ?? "") {
            if let best = biggest(regions), most(best.photos) {
                return Whereabouts(name: best.key)
            }
            if let both = pair(regions) { return Whereabouts(name: both) }
        }
        guard abroad, let geocoder else { return nil }

        var named: [String: Int] = [:]
        var continents: [String: (photos: Int, countries: Int)] = [:]
        for (code, photos) in countries {
            if let name = geocoder.countryName(code) { named[name, default: 0] += photos }
            if let continent = geocoder.continent(code) {
                continents[continent, default: (0, 0)].photos += photos
                continents[continent, default: (0, 0)].countries += 1
            }
        }
        if let best = biggest(named), most(best.photos) { return Whereabouts(name: best.key) }
        if let both = pair(named) { return Whereabouts(name: both) }
        if let (code, held) = continents.max(by: { $0.value.photos < $1.value.photos }),
           most(held.photos), held.countries >= 3, let name = Self.continents[code] {
            return Whereabouts(name: name)
        }
        return nil
    }

    /// Countries whose states and provinces are what people say they went
    /// to, abroad as at home: "Ten days in Ontario", "A week in Scotland".
    /// Elsewhere a trip abroad is named for the country.
    static let namedRegions: Set<String> = ["US", "CA", "AU", "NZ", "GB"]

    /// The continents a trip through several countries is named for. North
    /// America isn't one: a week in Vermont and Quebec isn't "in North
    /// America", and gets the pair of them instead.
    static let continents = [
        "EU": "Europe", "AS": "Asia", "AF": "Africa", "SA": "South America",
    ]

    // MARK: - Holidays and occasions

    /// A day that means something, and what it means.
    struct Occasion {
        let summary: CollectionSummary
        /// What the day *is* — "Christmas", "Mom's birthday" — without its year,
        /// so the page can offer each occasion once rather than every Christmas
        /// in a row. Nil for a date that only comes round busy every year,
        /// which See All offers to be named but the page doesn't lead with.
        let occasion: String?
        /// Found by what the photographs showed rather than by the calendar
        /// or a name. See `CurationVocabulary.events`.
        var isEvent = false
        /// Named for a holiday, which the person can turn off. See
        /// `CuratedAlbums`.
        var isHoliday = false
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
        /// Whether the day clears the occasions query's busy bar. Optional so
        /// a query that doesn't select it still decodes.
        var busy: Bool?
        /// Minutes with photos in them: a burst, or the same thing shot nine
        /// times, is one moment. Optional, like `busy`.
        var moments: Int?
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
    ///
    /// The same query brings back every year of what comes round every year
    /// (`yearly`), for Over the Years: those days are among the rows, and only
    /// the days this has always chosen become occasions. A date that comes
    /// round is asked about only where `yearly` found it a pattern, by the
    /// name it found for it.
    private func occasions(
        spaceID: UUID, seed: String, userID: UUID, named: [String: String],
        holidays: [String: String], events: [String: CurationVocabulary.Event] = [:],
        excluding claimed: Set<String>, recurring: Set<String>, yearly: YearlyPatterns,
        scope: EventScope = EventScope(), on sql: any SQLDatabase
    ) async throws -> (occasions: [Occasion], rows: [DayRow]) {
        let local = TimelineController.localTime

        // Joined and split rather than interpolated: these strings are
        // machine-generated dates, but a query that builds its own IN list is a
        // habit worth not having.
        //
        // A day the person's devices saw an occasion in clears the same bar as
        // a holiday: it is something, however busy it was.
        let specialDays = Set(holidays.keys).union(named.keys).union(events.keys)
        let special = specialDays.sorted().joined(separator: ",")
        let annual = recurring.sorted().joined(separator: ",")
        let extra = yearly.extraDays.subtracting(specialDays).sorted().joined(separator: ",")

        let rows = try await sql.raw("""
            WITH per_day AS (
                SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                       count(*)::int AS count,
                       mode() WITHIN GROUP (ORDER BY \(unsafeRaw: TimelineController.placeName)) AS place,
                       count(DISTINCT \(unsafeRaw: TimelineController.placeName))::int AS "placeCount",
                       count(*) FILTER (WHERE a.media_type = 'video')::int AS "videoCount",
                       min(EXTRACT(HOUR FROM \(unsafeRaw: local)))::int AS "firstHour",
                       max(EXTRACT(HOUR FROM \(unsafeRaw: local)))::int AS "lastHour",
                       count(DISTINCT COALESCE(sa.credited_to_user_id, sa.uploaded_by_user_id))::int
                           AS "peopleCount",
                       count(DISTINCT date_trunc('minute', \(unsafeRaw: local)))::int AS moments,
                       (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                           [1:\(unsafeRaw: String(Self.coverDepth))] AS cover
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                \(Self.observed(by: userID))
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                  \(scope.filter)
                GROUP BY day
            ),
            baseline AS (
                SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY count) AS median FROM per_day
            )
            SELECT p.day, p.count, p.place, p."placeCount", p."videoCount",
                   p."firstHour", p."lastHour", p."peopleCount", p.cover AS "coverAssetIDs", p.moments,
                   p.count >= GREATEST(b.median * 3, \(bind: Self.minimumItems * 2)) AS busy
            FROM per_day p, baseline b
            WHERE (p.day = ANY(string_to_array(\(bind: special), ','))
                   AND p.count >= \(bind: Self.minimumItems))
               OR (substr(p.day, 6) = ANY(string_to_array(\(bind: annual), ','))
                   AND p.count >= GREATEST(b.median * 3, \(bind: Self.minimumItems * 2)))
               OR (p.day = ANY(string_to_array(\(bind: extra), ','))
                   AND p.count >= \(bind: Self.minimumItems))
            ORDER BY p.day DESC
            LIMIT 5000
            """).all(decoding: DayRow.self)

        // The days this has always chosen, and as many: holidays, named days
        // and events, and dates that come round on a busy day. The rest of the
        // rows are other years of what comes round, for Over the Years.
        let chosen = rows
            .filter { specialDays.contains($0.day) || (recurring.contains(Self.monthDay($0.day)) && $0.busy == true) }
            .prefix(600)

        // A date that only recurs is offered once, in its latest year: what it
        // is asking for is a name, and one name covers every year of it. Only a
        // date that really does come round, though: one busy three times in
        // twenty years is a coincidence, and asking to name it was a question
        // with no answer.
        var offered = Set<String>()
        let found = Self.split(Self.runs(from: chosen.filter { !claimed.contains($0.day) }), by: events)
            .compactMap {
                Self.occasion(
                    $0, holidays: holidays, named: named, recurring: recurring, events: events,
                    dates: yearly.dates
                )
            }
            .filter { candidate in
                guard candidate.occasion == nil else { return true }
                guard let date = Self.days(inKey: candidate.summary.key).lazy
                    .map(Self.monthDay).first(where: { yearly.dates[$0] != nil })
                else { return false }
                return offered.insert(date).inserted
            }
            .prefix(Self.allOccasionsLimit)
            .map { $0 }
        return (found, rows)
    }

    /// A run as an occasion: its card, and what it is.
    static func occasion(
        _ run: Run,
        holidays: [String: String],
        named: [String: String],
        recurring: Set<String>,
        events: [String: CurationVocabulary.Event] = [:],
        dates: [String: String] = [:]
    ) -> Occasion? {
        guard var summary = describe(
            run, holidays: holidays, named: named, recurring: recurring, events: events
        ) else { return nil }
        let userName = run.days.compactMap { named[$0.day] }.first
        // Enough to look at, or it isn't an album: a burst of one thing and
        // a stray beside it says nothing. A day the person named is theirs to
        // keep, however few.
        if userName == nil {
            let needed = holiday(in: run, holidays: holidays) != nil ? Self.holidayMoments : Self.minimumMoments
            guard run.moments >= needed else { return nil }
        }
        let holidayName = userName == nil ? holiday(in: run, holidays: holidays)?.name : nil
        let given = userName ?? holidayName
        // An event only where nothing better names the day, matching the
        // order `describe` titles it in.
        let found = given == nil ? event(in: run, events: events) : nil
        let name = given ?? found?.title

        // A date photographed every year that nobody has named yet is almost
        // always a birthday or an anniversary, and saying so is the whole
        // reason to show it. "A busy Tuesday" told you nothing about why it was
        // here; this tells you, and the card offers to name it every year.
        //
        // By what Over the Years found it to be — "Birthday on April 5" where
        // its photos showed one — and by the date that comes round, which in
        // a run of days isn't always the first.
        if name == nil, summary.recursAnnually,
           let title = run.days.reversed().lazy.compactMap({ dates[monthDay($0.day)] }).first {
            summary = CollectionSummary(
                kind: summary.kind, key: summary.key,
                title: title,
                // The place back in: the old title carried it, this one doesn't.
                subtitle: subtitle(run, place: run.place), count: summary.count,
                coverAssetIDs: summary.coverAssetIDs, isNamed: summary.isNamed,
                recursAnnually: summary.recursAnnually
            )
        }
        return Occasion(
            summary: summary, occasion: name, isEvent: found != nil, isHoliday: holidayName != nil
        )
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
        var moments: Int { days.reduce(0) { $0 + ($1.moments ?? $1.count) } }
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

    // MARK: - What the photographs showed

    /// One day of a person's own library, as their devices saw it.
    struct DayEvidence {
        /// Everything the day holds.
        var total = 0
        /// How much of it has been analyzed.
        var analyzed = 0
        /// Analyzed, and a picture rather than a screenshot or a document:
        /// what shares are taken of.
        var usable = 0
        /// How many usable photos carry each tag.
        var tags: [String: Int] = [:]

        /// Whether enough of the day has been looked at to trust what wasn't
        /// found in it. Until then a day keeps the rules it had before
        /// curation, so the page doesn't thin out while a library is still
        /// being analyzed.
        var isAnalyzed: Bool { analyzed > 0 && analyzed * 2 >= total }

        func count(_ tag: String) -> Int { tags[tag, default: 0] }

        func share(_ tag: String) -> Double {
            usable > 0 ? Double(count(tag)) / Double(usable) : 0
        }
    }

    /// Every day of the library that the person's devices have seen any of.
    ///
    /// Two passes over the person's own library, both cheap next to the page's
    /// other queries: what each day holds, and how often each tag appears in
    /// it. Utility photos (screenshots, receipts, documents) count toward how
    /// much of a day was analyzed but are never evidence of an occasion.
    private func dayEvidence(
        spaceID: UUID, userID: UUID, source: ObservationSource, days: [String]? = nil,
        on sql: any SQLDatabase
    ) async throws -> [String: DayEvidence] {
        struct TotalRow: Decodable { let day: String; let total: Int; let analyzed: Int; let usable: Int }
        struct TagRow: Decodable { let day: String; let tag: String; let n: Int }
        let local = TimelineController.localTime
        let only: SQLQueryString
        if let days {
            only = "AND to_char(\(unsafeRaw: local), 'YYYY-MM-DD') = ANY(\(bind: days)::text[])"
        } else {
            only = ""
        }

        let totals = try await sql.raw("""
            SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day,
                   count(*)::int AS total,
                   count(o.sha256)::int AS analyzed,
                   count(o.sha256) FILTER (
                       WHERE NOT o.is_utility AND NOT ('utility' = ANY(o.tags))
                   )::int AS usable
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN \(unsafeRaw: source.table) o
                   ON o.user_id = \(bind: userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              \(only)
            GROUP BY 1
            HAVING count(o.sha256) > 0
            """).all(decoding: TotalRow.self)
        guard !totals.isEmpty else { return [:] }

        let tagged = try await sql.raw("""
            SELECT to_char(\(unsafeRaw: local), 'YYYY-MM-DD') AS day, t.tag, count(*)::int AS n
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN \(unsafeRaw: source.table) o ON o.user_id = \(bind: userID) AND o.sha256 = a.sha256
            CROSS JOIN LATERAL unnest(o.tags) AS t(tag)
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND NOT o.is_utility AND NOT ('utility' = ANY(o.tags))
              \(only)
            GROUP BY 1, 2
            """).all(decoding: TagRow.self)

        var evidence: [String: DayEvidence] = [:]
        for row in totals {
            evidence[row.day] = DayEvidence(
                total: row.total, analyzed: row.analyzed, usable: row.usable
            )
        }
        for row in tagged {
            evidence[row.day]?.tags[row.tag] = row.n
        }
        return evidence
    }

    /// What of a `.day` album's days was an event, worked out as the page
    /// works it out, for the album endpoint.
    func eventScope(
        forDays days: [String], spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws -> EventScope {
        guard !days.isEmpty else { return EventScope() }
        let curation = try await CurationController.context(userID: userID, spaceID: spaceID, on: sql)
        guard curation.enabled, curation.isPersonal else { return EventScope() }
        let evidence = try await dayEvidence(
            spaceID: spaceID, userID: userID, source: curation.source, days: days, on: sql
        )
        let years = Set(days.compactMap { Int($0.prefix(4)) }).sorted()
        let calendar = curation.holidays ? Holidays.table(forYears: years) : [:]
        let events = Self.events(in: evidence, excluding: Self.evidenced(calendar, by: evidence))
        guard !events.isEmpty else { return EventScope() }
        let named = try await occasionNames(spaceID: spaceID, userID: userID, years: years, on: sql)
        return try await Self.eventScope(
            spaceID: spaceID, userID: userID, source: curation.source, events: events, named: named, on: sql
        )
    }

    /// The holidays that looked like themselves.
    ///
    /// A holiday on a day the devices have looked at stays only if the day
    /// shows the evidence `CurationVocabulary.holidayEvidence` asks of it. One
    /// not looked at yet, or with no rule, keeps the date-only rule it always
    /// had.
    static func evidenced(
        _ holidays: [String: String], by evidence: [String: DayEvidence]
    ) -> [String: String] {
        holidays.filter { day, name in looksLike(name, on: day, by: evidence) != false }
    }

    /// Whether a holiday's photos look like it: nil until the devices have
    /// looked at its day. A holiday that asks for no evidence always does.
    static func looksLike(
        _ name: String, on day: String, by evidence: [String: DayEvidence]
    ) -> Bool? {
        guard let rules = CurationVocabulary.holidayEvidence[name] else { return true }
        guard let seen = evidence[day], seen.isAnalyzed else { return nil }
        return rules.contains { rule in
            seen.count(rule.tag) >= rule.minPhotos && seen.share(rule.tag) >= rule.minShare
        }
    }

    /// The days whose photographs show an occasion, and which: the first in
    /// `CurationVocabulary.events` that the day clears both bars for.
    ///
    /// Holidays are left to be holidays. A Fourth of July baseball game is
    /// the Fourth of July.
    static func events(
        in evidence: [String: DayEvidence], excluding holidays: [String: String]
    ) -> [String: CurationVocabulary.Event] {
        var found: [String: CurationVocabulary.Event] = [:]
        for (day, seen) in evidence where seen.isAnalyzed && holidays[day] == nil {
            found[day] = CurationVocabulary.event(
                clearing: { seen.count($0.tag) >= $0.minPhotos && seen.share($0.tag) >= $0.minShare },
                count: seen.count
            )
        }
        return found
    }

    /// What a trip turned out to be, over all of its days together: the first
    /// event that can name a trip and that enough of it shows.
    static func tripEvent(
        days: [String], evidence: [String: DayEvidence]
    ) -> CurationVocabulary.Event? {
        var whole = DayEvidence()
        for day in days {
            guard let seen = evidence[day] else { continue }
            whole.total += seen.total
            whole.analyzed += seen.analyzed
            whole.usable += seen.usable
            whole.tags.merge(seen.tags, uniquingKeysWith: +)
        }
        guard whole.isAnalyzed else { return nil }
        return CurationVocabulary.event(
            clearing: { event in
                event.tripTitle != nil
                    && whole.count(event.tag) >= event.minPhotos
                    && whole.share(event.tag) >= CurationVocabulary.tripShare
            },
            count: whole.count
        )
    }

    /// The event a run of days was, if any of its days was one. After `split`
    /// a run holds at most one kind.
    static func event(
        in run: Run, events: [String: CurationVocabulary.Event]
    ) -> CurationVocabulary.Event? {
        run.days.lazy.compactMap { events[$0.day] }.first
    }

    /// Splits runs where what the photographs showed changes, so a birthday on
    /// Saturday and a soccer game on Sunday are two occasions rather than one
    /// named for whichever came first. Christmas Eve into Christmas Day, with
    /// no event on either, stays one.
    static func split(_ runs: [Run], by events: [String: CurationVocabulary.Event]) -> [Run] {
        guard !events.isEmpty else { return runs }
        return runs.flatMap { run -> [Run] in
            var pieces: [Run] = []
            for day in run.days {
                if let previous = pieces.last?.days.last,
                   events[previous.day]?.tag == events[day.day]?.tag {
                    pieces[pieces.count - 1].days.append(day)
                } else {
                    pieces.append(Run(days: [day]))
                }
            }
            return pieces
        }
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
        recurring: Set<String> = [],
        events: [String: CurationVocabulary.Event] = [:]
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
        } else if let event = event(in: run, events: events) {
            // What the photographs showed, where the person's own devices
            // looked: "Birthday party in Culpeper". Earned the same way as
            // every rule below, so it outranks them.
            title = inPlace(event.title, place)
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
    ///
    /// Counted out by hand. The keys are this file's own `yyyy-MM-dd`, and a
    /// `DateFormatter` made for every day cost the Albums page more than half
    /// a millisecond a trip.
    static func days(inKey key: String) -> [String] {
        let ends = key.components(separatedBy: "..")
        guard let first = ends.first.flatMap(KeyDay.init),
              let last = ends.last.flatMap(KeyDay.init) else { return ends }
        var result: [String] = []
        var cursor = first
        while cursor <= last, result.count < 400 {
            result.append(Self.key(year: cursor.year, month: cursor.month, day: cursor.day))
            cursor = cursor.next
        }
        return result
    }

    /// A day of a run key, and the one after it.
    private struct KeyDay: Comparable {
        let year: Int
        let month: Int
        let day: Int

        init?(_ stamp: String) {
            let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
                  parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), (1...Self.length(of: month, in: year)).contains(day)
            else { return nil }
            self.init(year: year, month: month, day: day)
        }

        private init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        var next: KeyDay {
            if day < Self.length(of: month, in: year) { return KeyDay(year: year, month: month, day: day + 1) }
            if month < 12 { return KeyDay(year: year, month: month + 1, day: 1) }
            return KeyDay(year: year + 1, month: 1, day: 1)
        }

        static func length(of month: Int, in year: Int) -> Int {
            switch month {
            case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
            }
        }

        static func < (lhs: KeyDay, rhs: KeyDay) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    /// `"2026-08-14"` → `"08-14"`.
    static func monthDay(_ day: String) -> String {
        String(day.dropFirst(5))
    }

    /// Names a stretch of days. A weekend is worth recognizing by name; four
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

    /// "An evening in Culpeper", or "at Walt Disney World" — and just "An
    /// evening" where there is no location to name, rather than a sentence
    /// with a hole in it.
    static func inPlace(_ phrase: String, _ place: String?) -> String {
        guard let place else { return phrase }
        // The stored name is "Culpeper, Virginia"; a title wants the town.
        return "\(phrase) \(Whereabouts(label: place).locative)"
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
            parts.append(dateRange(from: from, to: to))
        }
        // The caller passes nil when the title already named the place, so a
        // card never reads "An evening in Culpeper · Culpeper, Virginia" — nor
        // "Three places in one day · Asheville", which is worse, because it
        // contradicts the line above it.
        if let place { parts.append(place) }
        if let videos = videoNote(videos: run.videoCount, of: run.count) { parts.append(videos) }
        return parts.joined(separator: " · ")
    }

    /// "3 videos", where a day's videos are worth a mention: some, but no more
    /// than half of it.
    static func videoNote(videos: Int, of count: Int) -> String? {
        guard videos > 0, videos * 2 <= count else { return nil }
        return videos == 1 ? "1 video" : "\(videos) videos"
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
        // Annual first so a year-specific name written afterward overwrites it.
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

    // Dates that come round — photographed in three or more years — are
    // `LibraryDays.recurring`, worked out from the one pass of the library's
    // days that Over the Years reads too. See `YearlyPatterns`.

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

    // MARK: - Trips every year

    /// Trips a family takes year after year: the same place and the same
    /// kind of stay, by the name the family gives it, in three years at
    /// least. "OBX Beach Week · Every July · 6 years". Each year is that
    /// year's trip, which opens as it does under Trips. A trip over a holiday
    /// is a year of that holiday instead, and has no year at the end of its
    /// name.
    static func tripTraditions(_ trips: [CollectionSummary], today: Date, turn: Int) -> [Tradition] {
        var byName: [String: [(trip: CollectionSummary, year: Int)]] = [:]
        for trip in trips where trip.kind == .trip {
            guard let (name, year) = yearless(trip.title), tripPlace(inTitle: trip.title) != nil else { continue }
            byName[name, default: []].append((trip, year))
        }
        let todayNumber = CivilDay.number(of: today)
        let thisYear = CivilDay.civil(todayNumber).year
        return byName.compactMap { name, found -> Tradition? in
            let years = Set(found.map(\.year))
            guard years.count >= 3, let first = years.min(), let last = years.max() else { return nil }
            let newest = found.map(\.trip).sorted { $0.key > $1.key }
            let starts = newest.compactMap { CivilDay.number(String($0.key.prefix(10))) }.map(CivilDay.civil)
            // "Every July", where two in three of them start in it.
            let months = Dictionary(grouping: starts.map(\.month), by: { $0 })
            let every = months.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
                .flatMap { $0.value.count * 3 >= starts.count * 2 ? "Every \(CivilDay.months[$0.key - 1])" : nil }
            // Next time round: the latest one's start date, in the year ahead.
            let next = starts.first.flatMap { start in
                (thisYear...thisYear + 1).lazy
                    .filter { CivilDay.isValid(year: $0, month: start.month, day: start.day) }
                    .map { CivilDay.number(year: $0, month: start.month, day: start.day) }
                    .first { $0 > todayNumber }
            }
            let turned = rotated(newest, by: turn)
            return Tradition(
                id: "trip:\(name.lowercased())", title: name,
                subtitle: [every, "\(years.count) years · \(first)–\(last)"].compactMap { $0 }.joined(separator: " · "),
                count: newest.reduce(0) { $0 + $1.count },
                coverAssetIDs: Array(turned.compactMap(\.coverAssetIDs.first).prefix(coverDepth)),
                years: Array(newest.prefix(YearlyPatterns.yearLimit).reversed()),
                next: next.map(CivilDay.stamp), naming: nil
            )
        }
    }

    /// Over the Years with the trips taken every year in it, the soonest to
    /// come round first, as the rest are.
    static func withTrips(
        _ traditions: [Tradition], trips: [CollectionSummary], today: Date, turn: Int
    ) -> [Tradition] {
        let found = tripTraditions(trips, today: today, turn: turn)
        guard !found.isEmpty else { return traditions }
        return (traditions + found)
            .sorted { a, b in
                switch (a.next, b.next) {
                case let (x?, y?) where x != y: return x < y
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
                if a.years.count != b.years.count { return a.years.count > b.years.count }
                return a.title < b.title
            }
            .prefix(YearlyPatterns.traditionLimit)
            .map { $0 }
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

            // "at Walt Disney World" from "WDW Vacation 2025": the place by
            // its whole name, as it's said in a sentence. A trip from before
            // says it after its preposition, and a trip *to* somewhere was a
            // time you were *in* it, or at it.
            let title: String
            if yearless(trip.title) != nil, let word = tripPlace(inTitle: trip.title) {
                let place = Destinations.place(titled: word).map(Whereabouts.init) ?? Whereabouts(name: word)
                title = "\(agoPhrase(ago)) you were \(place.locative)"
            } else if let (preposition, place) = whereabouts(inTitle: trip.title) {
                let locative = preposition == "to"
                    ? Whereabouts.locative(spoken: place)
                    : "\(preposition) \(place)"
                title = "\(agoPhrase(ago)) you were \(locative)"
            } else {
                title = "\(agoPhrase(ago)) you were away"
            }

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
        spaceID: UUID, seed: String, userID: UUID, on sql: any SQLDatabase
    ) async throws -> [CollectionSummary] {
        let local = TimelineController.localTime
        let place = TimelineController.placeName
        let rows = try await sql.raw("""
            SELECT \(unsafeRaw: place) AS place,
                   count(*)::int AS count,
                   to_char(max(\(unsafeRaw: local)), 'YYYY-MM-DD') AS "lastSeen",
                   (ARRAY_AGG(a.id ORDER BY \(unsafeRaw: Self.coverOrder(seed: seed))))
                       [1:\(unsafeRaw: String(Self.coverDepth))] AS "coverAssetIDs"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            \(Self.observed(by: userID))
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: place) IS NOT NULL
            GROUP BY 1
            HAVING count(*) >= \(bind: Self.minimumItems * 3)
               AND max(\(unsafeRaw: local)) < now() - interval '2 years'
            ORDER BY max(\(unsafeRaw: local)) DESC
            LIMIT 4
            """).all(decoding: RevisitRow.self)

        return rows.map { row in
            let town = HeaderPlaces.town(row.place)
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
        spaceID: UUID, today: Date, seed: String, userID: UUID, on sql: any SQLDatabase
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
            \(Self.observed(by: userID))
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
            return Season(name: "Last fall", span: "September – November \(year)",
                          from: "\(year)-09-01", to: "\(year)-11-30")
        }
    }

    // MARK: - Recently deleted

    private struct DeletedRow: Decodable {
        let count: Int
        let coverAssetID: UUID?
    }

    /// Removals inside their retention window, in any library.
    ///
    /// Shared libraries used to be left out, on the grounds that their removals
    /// were recovered through File Station. That stopped being true when shared
    /// photographs moved into each member's home: removing one withdraws every
    /// member's copy, straight past DSM's recycle bin, so a shared deletion had
    /// no way back at all for 29 days while the server still held the bytes.
    /// Who may undo whose deletion has the same answer as who may delete: any
    /// contributor may remove anyone's photograph from a shared library, so any
    /// contributor may put one back.
    ///
    /// This used to read `recycled_path` and stat the file, because the bytes
    /// sat in a bin DSM could empty from under us and a row was no proof the
    /// file was there. Retention moved the bytes back into the blob store,
    /// where nothing else reclaims them, so `purged_at` is now the whole
    /// answer — one column, no filesystem round trip per row.
    private func recentlyDeleted(
        spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws -> CollectionSummary? {
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
            SELECT count(*) AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NOT NULL
              AND sa.purged_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND \(Hidden.excluded(for: userID))
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
        spaceID: UUID, seed: String, userID: UUID, on sql: any SQLDatabase
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
                \(Self.observed(by: userID))
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

    /// Everything removed from this library and still recoverable, most
    /// recently removed first, each carrying the date it goes for good.
    ///
    /// Built from `TimelineController.itemColumns` like every other list of
    /// items. This one kept a hand-written column list, and it drifted the way
    /// that comment warns: no `thumbVersion`, so the app asked for version 0 of
    /// thumbnails it held cached as version 3 and could not reuse a single one.
    ///
    /// A Live Photo's video half is left out, as it is everywhere else: it is
    /// removed, restored and purged along with its still, never on its own.
    /// So is what this person has put out of their own sight — a photo they
    /// reported that its library's owner then removed, or anything from
    /// someone they blocked: a page that can open its photos full size must
    /// not be the way back to them. See `Hidden`.
    @Sendable
    func deletedItems(req: Request) async throws -> SearchResults {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   false AS "isFavorite",
                   -- The day this becomes unrecoverable, computed here so the
                   -- client never has to know the window to count down to it.
                   (sa.deleted_at + \(unsafeRaw: Retention.interval)) AT TIME ZONE 'UTC'
                       AS "purgeAt"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NOT NULL
              AND sa.purged_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND \(Hidden.excluded(for: device.userID))
            ORDER BY sa.deleted_at DESC, sa.id
            LIMIT 500
            """).all(decoding: TimelineController.ItemRow.self)

        let items = rows.map { $0.toItem() }
        return SearchResults(items: items, total: items.count, nextOffset: nil)
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
    ///
    /// One transaction for the batch and its announcements, like every other
    /// write that other devices have to hear about: it used to restore row by
    /// row with each announcement behind a `try?`, and one that failed left a
    /// photograph back in the library here and missing everywhere else.
    @Sendable
    func restore(req: Request) async throws -> MediaEditResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(RestoreAssetsRequest.self)
        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        let chosen = Array(input.assetIDs.prefix(500))
        guard !chosen.isEmpty else { return MediaEditResponse(updated: 0) }

        let restored = try await req.withPinnedConnection { sql -> Int in
            try await sql.raw("BEGIN").run()
            do {
                struct Row: Decodable { let id: UUID }
                let rows = try await sql.raw("""
                    UPDATE space_assets
                    SET deleted_at = NULL, deleted_by = NULL
                    WHERE space_id = \(bind: spaceID)
                      AND asset_id = ANY(\(bind: chosen))
                      AND deleted_at IS NOT NULL
                      AND purged_at IS NULL
                    RETURNING id
                    """).all(decoding: Row.self)

                // A Live Photo's motion comes back with its still — it was
                // removed with it. See `AssetController.remove`.
                try await sql.raw("""
                    UPDATE space_assets pv
                    SET deleted_at = NULL, deleted_by = NULL
                    FROM assets still, assets video
                    WHERE still.id = ANY(\(bind: chosen))
                      AND still.live_group_id IS NOT NULL
                      AND video.live_group_id = still.live_group_id
                      AND video.media_type = 'video'
                      AND video.id <> still.id
                      AND pv.asset_id = video.id
                      AND pv.space_id = \(bind: spaceID)
                      AND pv.deleted_at IS NOT NULL
                      AND pv.purged_at IS NULL
                    """).run()

                // And whatever was stacked under it, removed with it too.
                try await sql.raw("""
                    UPDATE space_assets pm
                    SET deleted_at = NULL, deleted_by = NULL
                    FROM assets member
                    WHERE member.stacked_under = ANY(\(bind: chosen))
                      AND pm.asset_id = member.id
                      AND pm.space_id = \(bind: spaceID)
                      AND pm.deleted_at IS NOT NULL
                      AND pm.purged_at IS NULL
                    """).run()

                for row in rows {
                    _ = try await ChangeLog.append(
                        spaceID: spaceID, entity: "space_asset", entityID: row.id,
                        op: "insert", on: sql
                    )
                }
                try await sql.raw("COMMIT").run()
                return rows.count
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
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
            let requested: Bool
        }

        let chosen = Array(input.assetIDs.prefix(500))
        guard !chosen.isEmpty else { return MediaEditResponse(updated: 0) }

        // The chosen removals, and the video half of any Live Photo among them —
        // it was removed with its still and goes for good with it too — and
        // whatever was stacked under one.
        let rows = try await req.sql.raw("""
            SELECT sa.id, a.sha256, a.blob_ext AS "blobExt",
                   (a.id = ANY(\(bind: chosen))) AS requested
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NOT NULL
              AND sa.purged_at IS NULL
              AND (a.id = ANY(\(bind: chosen))
                   OR a.stacked_under = ANY(\(bind: chosen))
                   OR (a.media_type = 'video' AND a.live_group_id IN (
                       SELECT still.live_group_id FROM assets still
                       WHERE still.id = ANY(\(bind: chosen))
                         AND still.live_group_id IS NOT NULL)))
            """).all(decoding: Row.self)

        for row in rows {
            await RetentionWorker.purge(
                placementID: row.id, sha256: row.sha256, blobExt: row.blobExt,
                on: req.sql, blobStore: req.blobStore, logger: req.logger
            )
        }
        return MediaEditResponse(updated: rows.filter(\.requested).count)
    }

    // MARK: - Contents

    /// The best few photos of a collection, in the order they were taken, with
    /// `total` saying how many it holds in all. Nil when the person's devices
    /// haven't analyzed enough of it to choose, and then the caller sends
    /// everything as before.
    ///
    /// "Best" means what a person would keep:
    /// - never a screenshot or a document, and only the chosen frame of a
    ///   burst;
    /// - one photo per two minutes at most, so ten near-identical shots of the
    ///   cake don't crowd out the rest of the party;
    /// - the highest aesthetic scores among what's left, shown in time order
    ///   so the highlights still tell the day in sequence.
    private func highlights(
        of filter: SQLQueryString, count: Int,
        spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws -> SearchResults? {
        let local = TimelineController.localTime

        struct Coverage: Decodable { let total: Int; let analyzed: Int }
        guard let coverage = try await sql.raw("""
            SELECT count(*)::int AS total, count(o.sha256)::int AS analyzed
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            \(Self.observed(by: userID))
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              \(filter)
            """).first(decoding: Coverage.self),
              coverage.total > count,
              coverage.analyzed * 2 >= coverage.total
        else { return nil }

        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT \(unsafeRaw: TimelineController.itemColumns),
                       EXISTS (
                           SELECT 1 FROM space_asset_favorites f
                           WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: userID)
                       ) AS "isFavorite",
                       \(unsafeRaw: local) AS taken,
                       COALESCE(o.aesthetic, -1) AS quality,
                       row_number() OVER (
                           PARTITION BY floor(extract(epoch FROM \(unsafeRaw: local)) / 120)
                           ORDER BY COALESCE(o.aesthetic, -1) DESC, sa.id
                       ) AS rank_in_moment
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                \(Self.observed(by: userID))
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                  AND NOT COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false)
                  AND (a.burst_id IS NULL OR a.burst_pick)
                  \(filter)
            ),
            best AS (
                SELECT * FROM candidates
                WHERE rank_in_moment = 1
                ORDER BY quality DESC, taken
                LIMIT \(bind: count)
            )
            SELECT * FROM best ORDER BY taken ASC
            """).all(decoding: TimelineController.ItemRow.self)

        return SearchResults(items: rows.map { $0.toItem() }, total: coverage.total, nextOffset: nil)
    }

    /// The photos in one collection, decoded from the key the summary carried.
    ///
    /// With `highlights=N`, the best N instead, where the person's devices have
    /// analyzed enough of it to tell. See `highlights(of:)`.
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

        // An event's album is the event, not the whole of its day. See
        // `EventScope`.
        let scope = kind == .day
            ? try await eventScope(forDays: Self.days(inKey: key), spaceID: spaceID, userID: device.userID, on: req.sql)
            : EventScope()
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
            // comparison wide however long the trip was.
            let ends = key.components(separatedBy: "..")
            let from = ends.first ?? key
            let to = ends.last ?? key
            filter = """
                AND to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD')
                    BETWEEN \(bind: from) AND \(bind: to)
                \(scope.filter)
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
            filter = "AND \(unsafeRaw: TimelineController.placeName) = \(bind: key)"
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
        case .together:
            // The photos two people are both in. The page no longer offers
            // these, but an app drawing a page it saved before may still
            // open one. Ids of anyone else's people simply find nothing.
            let ids = key.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard ids.count == 2 else {
                throw Abort(.badRequest, reason: "Together needs two people.")
            }
            filter = """
                AND EXISTS (
                    SELECT 1 FROM person_faces pf
                    JOIN people p ON p.id = pf.person_id
                    WHERE pf.person_id = \(bind: ids[0]) AND p.user_id = \(bind: device.userID)
                      AND pf.user_id = \(bind: device.userID) AND pf.sha256 = a.sha256
                      AND pf.state IN ('auto', 'confirmed')
                )
                AND EXISTS (
                    SELECT 1 FROM person_faces pf
                    JOIN people p ON p.id = pf.person_id
                    WHERE pf.person_id = \(bind: ids[1]) AND p.user_id = \(bind: device.userID)
                      AND pf.user_id = \(bind: device.userID) AND pf.sha256 = a.sha256
                      AND pf.state IN ('auto', 'confirmed')
                )
                """
        case .person:
            // Someone the NAS found in the caller's own library. Another
            // person's id simply finds nothing.
            guard let personID = UUID(uuidString: key) else {
                throw Abort(.badRequest, reason: "A person needs an id.")
            }
            filter = """
                AND EXISTS (
                    SELECT 1 FROM person_faces pf
                    JOIN people p ON p.id = pf.person_id
                    WHERE pf.person_id = \(bind: personID) AND p.user_id = \(bind: device.userID)
                      AND pf.user_id = \(bind: device.userID) AND pf.sha256 = a.sha256
                      AND pf.state IN ('auto', 'confirmed')
                )
                """
        }

        if let wanted = req.query[Int.self, at: "highlights"],
           let best = try await highlights(
               of: filter, count: min(max(wanted, 10), 100),
               spaceID: spaceID, userID: device.userID, on: req.sql
           ) {
            return best
        }

        // Someone can be in thousands of photos, where a trip is a few
        // hundred: a person's come newest first, a page at a time, with
        // `nextOffset` saying there's more. Every other kind is one answer in
        // the order things happened, as it always was.
        let byPage = kind == .person || kind == .together
        let offset = byPage ? max(0, req.query[Int.self, at: "offset"] ?? 0) : 0
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
            ORDER BY \(unsafeRaw: TimelineController.localTime) \(unsafeRaw: byPage ? "DESC" : "ASC"), sa.id
            LIMIT \(bind: byPage ? Self.personPage + 1 : 500) OFFSET \(bind: offset)
            """).all(decoding: TimelineController.ItemRow.self)

        if byPage {
            // Counted whole, so a page can say how many there are in all.
            struct Count: Decodable { let n: Int }
            let total = try await req.sql.raw("""
                SELECT count(*)::int AS n
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                  \(filter)
                """).first(decoding: Count.self)?.n ?? 0
            let more = rows.count > Self.personPage
            let items = rows.prefix(Self.personPage).map { $0.toItem() }
            return SearchResults(
                items: items, total: total,
                nextOffset: more ? offset + items.count : nil
            )
        }
        let items = rows.map { $0.toItem() }
        return SearchResults(items: items, total: items.count, nextOffset: nil)
    }

    /// How many of someone's photos one answer carries. Smaller in the smoke
    /// tests, so a few photos make more than a page.
    static let personPage = Environment.get("FRAMESTATION_PERSON_PAGE").flatMap(Int.init) ?? 300

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
    /// job a cover has, which is to make a card recognizable.
    /// How many photographs to send for a card.
    ///
    /// Five is what the hero cycles through. Sending them costs nothing — they
    /// are ids in a response that was being built anyway — and only the hero
    /// actually fetches beyond the first.
    static let coverDepth = 5

    ///
    /// Where the person's own devices have looked at the photos, what they saw
    /// comes next. A screenshot or a document never fronts a card, and a photo
    /// Vision rated good-looking goes ahead of one it didn't. That bias is
    /// still rotated by the seed, among the good ones, rather than crowning
    /// one photo for good. Expects the caller's observations joined as `o`;
    /// see `observed(by:)`. Where there are none, the order is what it always
    /// was.
    static func coverOrder(seed: String) -> String {
        """
        (a.derived_at IS NOT NULL) DESC,
        COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false) ASC,
        (COALESCE(o.aesthetic, 0) > \(goodLooking)) DESC,
        (a.camera_make IS NOT NULL) DESC,
        (a.burst_id IS NULL OR a.burst_pick) DESC,
        (a.media_type = 'photo') DESC,
        md5(a.id::text || '\(seed)')
        """
    }

    /// Vision's aesthetic score, from -1 to 1, above which a photo counts as
    /// good-looking enough to prefer for a cover. A starting point, to tune
    /// against real libraries.
    static let goodLooking = 0.1

    /// The caller's own observations, joined as `o`, for anything that reads
    /// quality off them. At most one row per photo, since observations are
    /// keyed by (person, file), so it never changes a count.
    static func observed(by userID: UUID) -> SQLQueryString {
        "LEFT JOIN media_observations o ON o.user_id = \(bind: userID) AND o.sha256 = a.sha256"
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

    /// "August 25, 2019".
    private static func dayLabel(month: Int, day: Int, year: Int) -> String {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Self.utc.date(from: components) else {
            return "\(year)"
        }
        return stampFormatter("MMMM d, yyyy").string(from: date)
    }

    /// "A busy Saturday" — the weekday is the part people actually recall about
    /// a day that mattered, more than its date.
    private static func weekdayTitle(_ key: String) -> String {
        guard let date = parseDate(key) else { return "A busy day" }
        return "A busy \(stampFormatter("EEEE").string(from: date))"
    }

    private static func longDay(_ key: String) -> String? {
        guard let date = parseDate(key) else { return nil }
        return stampFormatter("MMMM d, yyyy").string(from: date)
    }

    /// The days a trip or an occasion covers, the American way: "August
    /// 12–16, 2026" inside one month, "August 28 – September 2, 2026" across
    /// two, and "December 30, 2024 – January 2, 2025" across a new year, which
    /// needs both years. The month is said once where it doesn't change, and
    /// never left off one end only, which read as a mistake.
    static func dateRange(from: Date, to: Date) -> String {
        let sameYear = utc.component(.year, from: from) == utc.component(.year, from: to)
        let sameMonth = sameYear
            && utc.component(.month, from: from) == utc.component(.month, from: to)
        if sameMonth {
            return stampFormatter("MMMM d").string(from: from) + "–"
                + stampFormatter("d, yyyy").string(from: to)
        }
        let left = stampFormatter(sameYear ? "MMMM d" : "MMMM d, yyyy").string(from: from)
        return "\(left) – \(stampFormatter("MMMM d, yyyy").string(from: to))"
    }
}
