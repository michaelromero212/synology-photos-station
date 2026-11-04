import FrameStationAPI
import Foundation
import SQLKit

// MARK: - Over the Years
//
// The Albums page finds each Christmas, each day somebody named and each
// birthday party one at a time. This reads the same library along the
// calendar instead: what comes round every year, with each year of it, so
// someone's Christmases are one card rather than nine scattered through
// Holidays & Occasions.
//
// Worked out afresh on every visit, like the rest of the page, so a year joins
// its pattern the day its photos arrive. Next Christmas is part of "Christmas"
// the moment it's backed up, with nothing to run and nothing to migrate.
//
// The same rules for every library, and every bar is measured against the
// library it's applied to: its own ordinary days, its own busy ones, the weeks
// either side of each date. Two thousand photos and forty thousand are held to
// the same idea, never to one family's numbers.

/// Every day a library has photos on, and how many: the calendar the yearly
/// rules read.
///
/// One cheap pass of two columns. The page made the same pass before, to find
/// dates that come round, and kept only the dates.
struct LibraryDays {
    /// `YYYY-MM-DD` → photos that day, Recently Deleted left out.
    let counts: [String: Int]
    /// The library's ordinary day, worked out as the occasions query works it
    /// out: Postgres's `percentile_cont(0.5)` over the same counts.
    let median: Double

    init(counts: [String: Int]) {
        self.counts = counts
        let sorted = counts.values.sorted()
        if sorted.isEmpty {
            median = 0
        } else if sorted.count % 2 == 1 {
            median = Double(sorted[sorted.count / 2])
        } else {
            median = Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
    }

    /// What the occasions query calls busy: three times the ordinary day, and
    /// never fewer than eight photos.
    var busyBar: Double {
        max(median * 3, Double(CollectionsController.minimumItems * 2))
    }

    /// Dates with at least `minimumItems` photos in three or more years,
    /// `MM-DD`: what the page has always called a date that recurs, and what
    /// `CollectionSummary.recursAnnually` still means. The yearly rules ask
    /// more of a date than this before calling it one.
    var recurring: Set<String> {
        var years: [Substring: Set<Substring>] = [:]
        for (day, count) in counts where count >= CollectionsController.minimumItems && day.count == 10 {
            years[day.dropFirst(5), default: []].insert(day.prefix(4))
        }
        return Set(years.filter { $0.value.count >= 3 }.keys.map(String.init))
    }
}

extension CollectionsController {
    /// Every day of a library, with how many photos are on it.
    func libraryDays(spaceID: UUID, on sql: any SQLDatabase) async throws -> LibraryDays {
        struct Row: Decodable {
            let day: String
            let count: Int
        }
        let rows = try await sql.raw("""
            SELECT to_char(\(unsafeRaw: TimelineController.localTime), 'YYYY-MM-DD') AS day,
                   count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            GROUP BY 1
            """).all(decoding: Row.self)
        return LibraryDays(counts: Dictionary(rows.map { ($0.day, $0.count) }, uniquingKeysWith: +))
    }

    /// The names this person gave a date for every year, by `MM-DD`.
    func annualNames(
        spaceID: UUID, userID: UUID, on sql: any SQLDatabase
    ) async throws -> [String: String] {
        struct Row: Decodable {
            let month: Int
            let day: Int
            let name: String
        }
        let rows = try await sql.raw("""
            SELECT month, day, name FROM occasion_names
            WHERE user_id = \(bind: userID) AND space_id = \(bind: spaceID) AND year IS NULL
            """).all(decoding: Row.self)
        var names: [String: String] = [:]
        for row in rows {
            names[CivilDay.monthDayStamp(month: row.month, day: row.day)] = row.name
        }
        return names
    }
}

/// What comes round every year in one person's library.
///
/// Planned from the calendar before the page's occasions query runs, so the
/// query can bring back every year of each, then drawn from what it brings
/// back. Four kinds, tried in this order, each day belonging to one:
///
/// 1. Holidays: each holiday across the years it looked like itself, with
///    Christmas Eve and Christmas Day one Christmas, and New Year's Eve and
///    New Year's Day one New Year's.
/// 2. A name somebody gave a date for every year.
/// 3. The same kind of event at about the same time every year, such as a
///    birthday party held the weekend nearest a birthday.
/// 4. A date photographed far more often than the weeks around it, called a
///    birthday when the photos on it show one.
///
/// Two years make a holiday or a named day a tradition: what the day is is
/// already known. Three years for one found in the photos, since two years
/// in a row is a coincidence often enough.
struct YearlyPatterns {
    enum Source: Equatable {
        case holiday(family: String)
        case named
        case date
        case event(tag: String)
    }

    struct Pattern {
        let id: String
        var title: String
        let source: Source
        /// The date it falls on, `MM-DD`, for a date or a name. For an event,
        /// the middle of the dates it has fallen on.
        var monthDay: String?
        /// Each time it came round, as that time's days in order. Newest first.
        var members: [[String]]
        /// Days among `members` that were an event near the date rather than
        /// the date itself: the party held the Saturday after a birthday.
        var eventDays: Set<String> = []
    }

    var patterns: [Pattern] = []
    /// `MM-DD` → what the page calls a date that comes round: "Birthday on
    /// April 5". The Holidays & Occasions card asking to name that date says
    /// the same, and a date that isn't here isn't asked about.
    var dates: [String: String] = [:]
    /// Days the occasions query also has to bring back, so every year of a
    /// date can be drawn: holidays, names and events are among its days
    /// already.
    var extraDays: Set<String> = []

    // MARK: Bars

    /// How far either side of a date its neighbors reach: a month in all.
    static let neighborhood = 15
    /// How unlikely a date's photos must be by chance alone, given how often
    /// the weeks around it are photographed, before it counts as a pattern.
    /// About one false date in a thousand tested, and a library tests a few
    /// hundred.
    static let significance = 0.001
    /// The same for a holiday, whose date is already a reason to expect
    /// photos, and of which there are a dozen to test rather than hundreds.
    static let holidaySignificance = 0.02
    /// How far either side of its middle an event can fall and still be the
    /// same event: a birthday party moves with the weekends.
    static let eventSpread = 14
    /// A birthday party this close to a date is that date's party.
    static let partyReach = 3
    /// Birthday parties held around this close to a date photographed every
    /// year are that birthday's parties: the middle of the weekends they fell
    /// on. Ten days reached the next birthday over, and called an anniversary
    /// a week after a child's parties a birthday.
    static let birthdayReach = 4
    /// Events that don't come round: the next wedding is somebody else's.
    static let oneOffEvents: Set<String> = ["wedding", "graduation"]
    /// What one tradition sends, and how many the page gets. Bounded, like
    /// the rest of the page, so the response doesn't grow forever.
    static let yearLimit = 25
    static let traditionLimit = 24

    /// Christmas Eve and Christmas are one Christmas, and the turn of the year
    /// is one New Year's; every other holiday is its own.
    static func family(of holiday: String) -> String {
        switch holiday {
        case "Christmas Eve", "Christmas": return "Christmas"
        case "New Year's Eve", "New Year's Day": return "New Year's"
        default: return holiday
        }
    }

    // MARK: - Planning

    /// One event a year: a run of days the person's devices saw the same kind
    /// of event on.
    struct Occurrence {
        let tag: String
        var numbers: [Int]
        let year: Int
        /// Where in the year it began. See `CivilDay.position`.
        let position: Int
    }

    struct Cluster {
        let event: CurationVocabulary.Event
        let center: Int
        var members: [Occurrence]
        var years: Int { Set(members.map(\.year)).count }
    }

    /// A year of a date, as the rules weigh it.
    struct YearTest {
        let photographed: Bool
        let busy: Bool
        /// Of the days around it that year: how many, how many were
        /// photographed, and how many were busy.
        let nearDays: Int
        let nearPhotographed: Int
        let nearBusy: Int
    }

    static func plan(
        days: LibraryDays, years: [Int], today: Date,
        holidays: [String: String], calendar: [String: String],
        named: [String: String], annual: [String: String],
        events: [String: CurationVocabulary.Event],
        evidence: [String: CollectionsController.DayEvidence],
        claimed: Set<String>
    ) -> YearlyPatterns {
        var result = YearlyPatterns()
        let minimum = CollectionsController.minimumItems
        let todayNumber = CivilDay.number(of: today)
        let ascending = years.sorted()

        var countAt: [Int: Int] = [:]
        countAt.reserveCapacity(days.counts.count)
        for (stamp, count) in days.counts {
            if let number = CivilDay.number(stamp) { countAt[number, default: 0] += count }
        }
        let holidayNumbers = Set(holidays.keys.compactMap(CivilDay.number))
        let claimedNumbers = Set(claimed.compactMap(CivilDay.number))
        // A name on one of these dates is the name of that holiday.
        let fixed: Set<String> = calendar.isEmpty ? [] : Holidays.fixedMonthDays
        var used = Set<String>()

        // 1. Holidays.
        var families: [String: [Int]] = [:]
        for (stamp, name) in holidays where (days.counts[stamp] ?? 0) >= minimum {
            guard let number = CivilDay.number(stamp) else { continue }
            // A moving holiday that landed on a date somebody named for every
            // year is that date's, that year. Their name says what it was.
            if annual[String(stamp.dropFirst(5))] != nil, !fixed.contains(String(stamp.dropFirst(5))) {
                continue
            }
            families[family(of: name), default: []].append(number)
        }
        // Every year of each holiday the library holds, photographed or not,
        // to tell one the family marks from one that only happened.
        var seasonsOf: [String: [Int: [Int]]] = [:]
        for (stamp, name) in calendar {
            guard let number = CivilDay.number(stamp) else { continue }
            seasonsOf[family(of: name), default: [:]][season(of: [number]), default: []].append(number)
        }
        let calendarNumbers = Set(calendar.keys.compactMap(CivilDay.number))
        for (family, numbers) in families.sorted(by: { $0.key < $1.key }) {
            let runs = CivilDay.consecutive(numbers.sorted())
            guard Set(runs.map(season(of:))).count >= 2 else { continue }
            // Its own photos say so — a tree, fireworks, a table of family —
            // in two years at least, or the day stands out from the weeks
            // around it. A Memorial Day that only happened to have a few
            // photos, twice in fifteen years, is a coincidence, and so is any
            // holiday a family doesn't keep.
            let confirmed = Set(runs.filter { run in
                run.contains { number in
                    let stamp = CivilDay.stamp(number)
                    return holidays[stamp].map { confirms($0, on: stamp, by: evidence) } ?? false
                }
            }.map(season(of:)))
            if confirmed.count < 2 {
                var tests: [YearTest] = []
                for (_, dates) in (seasonsOf[family] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard dates.allSatisfy({ $0 <= todayNumber }),
                          !dates.contains(where: claimedNumbers.contains) else { continue }
                    let kept = dates.filter { holidays[CivilDay.stamp($0)] != nil }
                    let photos = kept.map { countAt[$0] ?? 0 }
                    var near = (days: 0, any: 0, photographed: 0, busy: 0)
                    var seen = Set(dates)
                    for date in dates {
                        for offset in -neighborhood...neighborhood {
                            let other = date + offset
                            guard seen.insert(other).inserted, !calendarNumbers.contains(other),
                                  !claimedNumbers.contains(other) else { continue }
                            let count = countAt[other] ?? 0
                            near.days += 1
                            if count > 0 { near.any += 1 }
                            if count >= minimum { near.photographed += 1 }
                            if Double(count) >= days.busyBar { near.busy += 1 }
                        }
                    }
                    guard photos.contains(where: { $0 > 0 }) || near.any > 0 else { continue }
                    tests.append(YearTest(
                        photographed: photos.contains { $0 >= minimum },
                        busy: photos.contains { Double($0) >= days.busyBar },
                        nearDays: near.days, nearPhotographed: near.photographed, nearBusy: near.busy
                    ))
                }
                guard significant(tests, threshold: holidaySignificance, fewest: 2) else { continue }
            }
            // "Christmas at Grandma's", every year: what they call it.
            let renamed = runs.reversed().lazy.compactMap { run in
                run.lazy.compactMap { annual[CivilDay.monthDayStamp($0)] }.first
            }.first
            result.patterns.append(Pattern(
                id: "holiday:\(family)", title: renamed ?? family, source: .holiday(family: family),
                members: runs.reversed().map { $0.map(CivilDay.stamp) }
            ))
            used.formUnion(numbers.map(CivilDay.stamp))
        }

        // 2. Names somebody gave a date for every year.
        for (monthDay, name) in annual.sorted(by: { $0.key < $1.key }) where !fixed.contains(monthDay) {
            guard let (month, day) = CivilDay.monthDay(monthDay) else { continue }
            var members: [[String]] = []
            for year in ascending.reversed() where CivilDay.isValid(year: year, month: month, day: day) {
                let number = CivilDay.number(year: year, month: month, day: day)
                let stamp = CivilDay.stamp(number)
                guard number <= todayNumber, (countAt[number] ?? 0) >= minimum, !used.contains(stamp)
                else { continue }
                members.append([stamp])
            }
            guard members.count >= 2 else { continue }
            result.patterns.append(Pattern(
                id: "date:\(monthDay)", title: name, source: .named, monthDay: monthDay, members: members
            ))
            used.formUnion(members.joined())
        }

        // 3. The same kind of event at about the same time every year. Away
        // from trips, which are their own thing, and from the days above.
        var occurrences: [Occurrence] = []
        let eventNumbers = events.compactMap { stamp, event -> (number: Int, tag: String)? in
            guard !oneOffEvents.contains(event.tag), (days.counts[stamp] ?? 0) >= minimum,
                  !claimed.contains(stamp), !used.contains(stamp),
                  let number = CivilDay.number(stamp) else { return nil }
            return (number, event.tag)
        }.sorted { $0.number < $1.number }
        for (number, tag) in eventNumbers {
            if let last = occurrences.last, last.tag == tag, last.numbers.last == number - 1 {
                occurrences[occurrences.count - 1].numbers.append(number)
            } else {
                let (year, month, day) = CivilDay.civil(number)
                occurrences.append(Occurrence(
                    tag: tag, numbers: [number], year: year,
                    position: CivilDay.position(month: month, day: day)
                ))
            }
        }
        var clusters = Self.clusters(of: occurrences)

        // 4. Dates photographed far more often than the weeks around them.
        let busyBar = days.busyBar
        for monthDay in days.recurring.sorted() where annual[monthDay] == nil {
            guard let (month, day) = CivilDay.monthDay(monthDay) else { continue }
            var members: [Int] = []
            var birthdays = Set<Int>()
            // Each kind of event, and the years it happened on the date itself.
            var onTheDay: [String: Set<Int>] = [:]
            var tests: [YearTest] = []
            for year in ascending where CivilDay.isValid(year: year, month: month, day: day) {
                let number = CivilDay.number(year: year, month: month, day: day)
                guard number <= todayNumber else { continue }
                // A wedding or a graduation that fell on the date was that,
                // and once: not a year of a birthday, nor evidence of one.
                if let event = events[CivilDay.stamp(number)], oneOffEvents.contains(event.tag) { continue }
                let isHoliday = holidayNumbers.contains(number)
                // December 25 is Christmas, which has its own card. A birthday
                // on Easter Sunday is still that birthday, though, and stays a
                // year of it.
                if isHoliday, fixed.contains(monthDay) { continue }
                let count = countAt[number] ?? 0
                if count >= minimum { members.append(number) }
                if isBirthday(around: number, events: events, evidence: evidence) { birthdays.insert(year) }
                if let tag = events[CivilDay.stamp(number)]?.tag { onTheDay[tag, default: []].insert(year) }
                // Days away say nothing about the date, and nor does a
                // holiday: a vacation or an Easter is busy whatever the date
                // is.
                guard !claimedNumbers.contains(number), !isHoliday else { continue }
                var near = (days: 0, any: 0, photographed: 0, busy: 0)
                for offset in -neighborhood...neighborhood where offset != 0 {
                    let other = number + offset
                    guard !holidayNumbers.contains(other), !claimedNumbers.contains(other) else { continue }
                    let photos = countAt[other] ?? 0
                    near.days += 1
                    if photos > 0 { near.any += 1 }
                    if photos >= minimum { near.photographed += 1 }
                    if Double(photos) >= busyBar { near.busy += 1 }
                }
                // A year the library holds nothing from, around then, says
                // nothing either way.
                guard count > 0 || near.any > 0 else { continue }
                tests.append(YearTest(
                    photographed: count >= minimum, busy: Double(count) >= busyBar,
                    nearDays: near.days, nearPhotographed: near.photographed, nearBusy: near.busy
                ))
            }
            guard members.count >= 3 else { continue }

            // The birthday parties held near it, most years: that birthday's.
            let position = CivilDay.position(month: month, day: day)
            let parties = clusters.indices.filter {
                clusters[$0].event.tag == "birthday"
                    && CivilDay.distance(clusters[$0].center, position) <= birthdayReach
            }
            for index in parties {
                for member in clusters[index].members { birthdays.insert(member.year) }
            }
            // Another event that falls on the date itself in two of its years
            // at least: a parade every St. Patrick's Day. Not one that merely
            // happens around then. A summer of concerts near August 10 doesn't
            // make August 10, a day of photos of the dog, a concert.
            let alike = clusters.indices.filter {
                clusters[$0].event.tag != "birthday"
                    && (onTheDay[clusters[$0].event.tag]?.count ?? 0) >= 2
                    && CivilDay.distance(clusters[$0].center, position) <= eventSpread
            }
            let alikeEvent = alike.first.map { clusters[$0].event }

            let showsIt = birthdays.count >= 2
            guard significant(tests) || showsIt || !alike.isEmpty else { continue }

            var pattern = Pattern(
                id: "date:\(monthDay)", title: "", source: .date, monthDay: monthDay,
                members: members.map { [CivilDay.stamp($0)] }
            )
            // The parties join it. One that took in the date itself replaces
            // the date's own card that year, since it holds the same photos and
            // more.
            for index in (parties + alike).sorted(by: >) {
                for occurrence in clusters[index].members {
                    let stamps = occurrence.numbers.map(CivilDay.stamp)
                    pattern.members.removeAll { $0.allSatisfy(stamps.contains) }
                    pattern.members.append(stamps)
                    pattern.eventDays.formUnion(stamps)
                }
                clusters.remove(at: index)
            }
            pattern.members.sort { ($0.first ?? "") > ($1.first ?? "") }
            let spoken = CivilDay.spoken(month: month, day: day)
            if !birthdays.isEmpty {
                pattern.title = "Birthday on \(spoken)"
            } else if let event = alikeEvent {
                pattern.title = "\(event.title) on \(spoken)"
            } else {
                pattern.title = "Every year on \(spoken)"
            }
            result.dates[monthDay] = pattern.title
            result.extraDays.formUnion(pattern.members.joined())
            result.patterns.append(pattern)
        }

        // What's left of 3, now that dates have taken their days.
        let dated = result.extraDays
        var months: [String: Int] = [:]
        for var cluster in clusters {
            cluster.members.removeAll { $0.numbers.contains { dated.contains(CivilDay.stamp($0)) } }
            guard cluster.years >= 3 else { continue }
            let (month, _) = CivilDay.monthDay(atPosition: cluster.center)
            let base = "event:\(cluster.event.tag):\(String(format: "%02d", month))"
            months[base, default: 0] += 1
            let id = months[base] == 1 ? base : "\(base)-\(months[base] ?? 1)"
            result.patterns.append(Pattern(
                id: id, title: cluster.event.title, source: .event(tag: cluster.event.tag),
                monthDay: CivilDay.monthDayStamp(atPosition: cluster.center),
                members: cluster.members
                    .sorted { $0.numbers[0] > $1.numbers[0] }
                    .map { $0.numbers.map(CivilDay.stamp) }
            ))
        }
        return result
    }

    /// Whether a holiday's own photos say it was that holiday: they clear its
    /// evidence, and not on the strength of a crowd alone when they show
    /// something else that explains the crowd, such as the game or the party.
    /// A Memorial Day that was a volleyball tournament was a volleyball
    /// tournament, and a birthday party on Mother's Day was a birthday party,
    /// as far as a tradition is concerned. Holidays & Occasions still calls
    /// the day what the calendar does.
    static func confirms(
        _ holiday: String, on day: String, by evidence: [String: CollectionsController.DayEvidence]
    ) -> Bool {
        guard let rules = CurationVocabulary.holidayEvidence[holiday],
              let seen = evidence[day], seen.isAnalyzed else { return false }
        let met = rules.filter { seen.count($0.tag) >= $0.minPhotos && seen.share($0.tag) >= $0.minShare }
        guard !met.isEmpty else { return false }
        if met.contains(where: { $0.tag != "gathering" }) { return true }
        return CurationVocabulary.event(
            clearing: { seen.count($0.tag) >= $0.minPhotos && seen.share($0.tag) >= $0.minShare },
            count: seen.count
        ) == nil
    }

    /// The year a holiday's days belong to. New Year's Eve rings in the year
    /// after it.
    static func season(of run: [Int]) -> Int {
        let (year, month, day) = CivilDay.civil(run.first ?? 0)
        return month == 12 && day == 31 ? year + 1 : year
    }

    /// Whether a date's photos showed a birthday: a birthday party on it, cake
    /// and candles in a couple of its photos, or a party within a few days.
    static func isBirthday(
        around number: Int, events: [String: CurationVocabulary.Event],
        evidence: [String: CollectionsController.DayEvidence]
    ) -> Bool {
        let stamp = CivilDay.stamp(number)
        if events[stamp]?.tag == "birthday" { return true }
        if (evidence[stamp]?.count("birthday") ?? 0) >= 2 { return true }
        return (-partyReach...partyReach).contains { offset in
            offset != 0 && events[CivilDay.stamp(number + offset)]?.tag == "birthday"
        }
    }

    /// Whether a date's years stand out from the weeks around them, by more
    /// than chance would: photographed, or busy, more often than its neighbors
    /// were in the same years.
    ///
    /// From the first year it was photographed to the last, so a birthday that
    /// began four years ago counts its four years and not the twenty before,
    /// and one the family stopped marking keeps the years it was. The first of
    /// those is left out of the reckoning, since it is where the count starts
    /// by construction.
    static func significant(
        _ tests: [YearTest], threshold: Double = significance, fewest: Int = 3
    ) -> Bool {
        guard let first = tests.firstIndex(where: \.photographed),
              let last = tests.lastIndex(where: \.photographed) else { return false }
        let span = tests[first...last]
        guard span.filter(\.photographed).count >= fewest else { return false }
        let rest = span.dropFirst()
        let nearDays = span.reduce(0) { $0 + $1.nearDays }
        // Never certain either way: one more photographed day and one more
        // quiet one than were seen.
        let photographedRate = Double(span.reduce(0) { $0 + $1.nearPhotographed } + 1) / Double(nearDays + 2)
        let busyRate = Double(span.reduce(0) { $0 + $1.nearBusy } + 1) / Double(nearDays + 2)
        return upperTail(n: rest.count, k: rest.filter(\.photographed).count, p: photographedRate) <= threshold
            || upperTail(n: rest.count, k: rest.filter(\.busy).count, p: busyRate) <= threshold
    }

    /// How likely `k` or more of `n` years would be, by chance alone, at rate `p`.
    static func upperTail(n: Int, k: Int, p: Double) -> Double {
        guard k > 0 else { return 1 }
        guard k <= n else { return 0 }
        let p = min(max(p, 1e-9), 1 - 1e-9)
        var total = 0.0
        for i in k...n {
            let ways = lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1))
            total += exp(ways + Double(i) * log(p) + Double(n - i) * log1p(-p))
        }
        return min(total, 1)
    }

    /// The events of each kind that come round at about the same time every
    /// year, at least three years of them, and about once a year: a pool day
    /// every summer weekend is a season, which is another thing.
    static func clusters(of occurrences: [Occurrence]) -> [Cluster] {
        var found: [Cluster] = []
        let byTag = Dictionary(grouping: occurrences, by: \.tag)
        for (tag, list) in byTag.sorted(by: { $0.key < $1.key }) {
            guard let event = CurationVocabulary.events.first(where: { $0.tag == tag }) else { continue }
            var remaining = list
            while remaining.count >= 3 {
                var best: (members: [Occurrence], center: Int, years: Int, spread: Int)?
                for seed in remaining {
                    let near = remaining.filter { CivilDay.distance($0.position, seed.position) <= eventSpread }
                    let center = CivilDay.middle(of: near.map(\.position))
                    let members = remaining.filter { CivilDay.distance($0.position, center) <= eventSpread }
                    let years = Set(members.map(\.year)).count
                    let spread = members.reduce(0) { $0 + CivilDay.distance($1.position, center) }
                    if years >= 3,
                       best == nil || years > best!.years || (years == best!.years && spread < best!.spread) {
                        best = (members, center, years, spread)
                    }
                }
                guard let chosen = best else { break }
                let taken = Set(chosen.members.map { $0.numbers[0] })
                remaining.removeAll { taken.contains($0.numbers[0]) }
                guard Double(chosen.members.count) <= Double(chosen.years) * 1.5 else { continue }
                found.append(Cluster(event: event, center: chosen.center, members: chosen.members))
            }
        }
        return found
    }

    // MARK: - Drawing

    /// The traditions themselves, from the days the occasions query brought
    /// back. The soonest to come round first.
    func traditions(
        rows: [CollectionsController.DayRow], today: Date, turn: Int,
        holidays: [String: String], named: [String: String], annual: [String: String],
        events: [String: CurationVocabulary.Event]
    ) -> [Tradition] {
        let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let todayNumber = CivilDay.number(of: today)
        let thisYear = CivilDay.civil(todayNumber).year
        let calendar = Holidays.table(forYears: [thisYear, thisYear + 1])

        var drawn: [(tradition: Tradition, wait: Int, years: Int)] = []
        for pattern in patterns {
            var cards: [(summary: CollectionSummary, year: Int, place: String?)] = []
            for member in pattern.members {
                let found = member.compactMap { byDay[$0] }
                guard !found.isEmpty else { continue }
                // Newest first, as a run is.
                let run = CollectionsController.Run(days: found.reversed())
                cards.append(card(for: run, in: pattern, holidays: holidays, named: named, annual: annual, events: events))
            }
            let years = Set(cards.map(\.year))
            switch pattern.source {
            case .holiday, .named: guard years.count >= 2 else { continue }
            case .date, .event: guard years.count >= 3 else { continue }
            }

            var title = pattern.title
            if case .event = pattern.source {
                // Where it happens, when it's mostly in one place:
                // "Birthday party in Linton Hall".
                let places = cards.compactMap(\.place)
                let common = Dictionary(grouping: places, by: { $0 }).max {
                    $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key
                }
                if let common, common.value.count * 4 >= cards.count * 3 {
                    title = CollectionsController.inPlace(pattern.title, common.key)
                }
            }

            let first = years.min() ?? thisYear
            let last = years.max() ?? thisYear
            let span = "\(years.count) years · \(first)–\(last)"
            let subtitle: String
            switch pattern.source {
            case .holiday, .date:
                subtitle = span
            case .named:
                let spoken = pattern.monthDay.flatMap { CivilDay.monthDay($0) }.map { CivilDay.spoken(month: $0.0, day: $0.1) }
                subtitle = [spoken, span].compactMap { $0 }.joined(separator: " · ")
            case .event:
                let month = pattern.monthDay.flatMap { CivilDay.monthDay($0) }.map { CivilDay.months[$0.0 - 1] }
                subtitle = [month.map { "Every \($0)" }, span].compactMap { $0 }.joined(separator: " · ")
            }

            let summaries = cards.map(\.summary)
            // A different year on the card each day, and the same all day.
            let turned = CollectionsController.rotated(summaries, by: turn)
            let covers = Array(turned.compactMap(\.coverAssetIDs.first).prefix(CollectionsController.coverDepth))

            let next = Self.next(pattern, after: todayNumber, holidays: calendar)
            let tradition = Tradition(
                id: pattern.id, title: title, subtitle: subtitle,
                count: summaries.reduce(0) { $0 + $1.count },
                coverAssetIDs: covers,
                years: Array(summaries.prefix(Self.yearLimit)),
                next: next.map(CivilDay.stamp),
                naming: naming(pattern, cards: summaries, title: title)
            )
            drawn.append((tradition, next.map { $0 - todayNumber } ?? Int.max, years.count))
        }
        return drawn
            .sorted { a, b in
                if a.wait != b.wait { return a.wait < b.wait }
                if a.years != b.years { return a.years > b.years }
                return a.tradition.title < b.tradition.title
            }
            .prefix(Self.traditionLimit)
            .map(\.tradition)
    }

    /// One year of a tradition, as a card that opens on its own photos.
    private func card(
        for run: CollectionsController.Run, in pattern: Pattern,
        holidays: [String: String], named: [String: String], annual: [String: String],
        events: [String: CurationVocabulary.Event]
    ) -> (summary: CollectionSummary, year: Int, place: String?) {
        let stamps = run.days.map(\.day).reversed()           // oldest first
        let firstNumber = CivilDay.number(run.first.day) ?? 0
        let lastNumber = CivilDay.number(run.last.day) ?? firstNumber
        let year = Self.season(of: [firstNumber])
        let place = run.place
        let videos = CollectionsController.videoNote(videos: run.videoCount, of: run.count)
        let userName = run.days.lazy.compactMap { named[$0.day] }.first
        let everyYear = stamps.lazy.compactMap { annual[String($0.dropFirst(5))] }.first

        var title: String
        var subtitle: [String?]
        switch pattern.source {
        case .holiday:
            // As Holidays & Occasions calls it: "Christmas 2025", or what
            // somebody renamed that year.
            let holiday = CollectionsController.holiday(in: run, holidays: holidays)
            title = userName ?? holiday.map { "\($0.name) \($0.day.prefix(4))" } ?? "\(pattern.title) \(year)"
            if let userName, userName == everyYear { title = "\(userName) \(year)" }
            subtitle = [CivilDay.range(firstNumber, lastNumber), place, videos]
        case .named:
            title = userName ?? pattern.title
            if title == everyYear || title == pattern.title { title = "\(title) \(year)" }
            subtitle = [CivilDay.range(firstNumber, lastNumber), place, videos]
        case .date where !pattern.eventDays.isDisjoint(with: stamps):
            // The party held near the date: what Holidays & Occasions called it.
            let event = run.days.lazy.compactMap { events[$0.day] }.first
            title = userName ?? event.map { CollectionsController.inPlace($0.title, place) }
                ?? CivilDay.range(firstNumber, lastNumber)
            subtitle = [CivilDay.range(firstNumber, lastNumber), videos]
        case .date, .event:
            title = userName ?? CivilDay.range(firstNumber, lastNumber)
            subtitle = [firstNumber == lastNumber ? CivilDay.weekday(firstNumber) : nil, place, videos]
        }

        let summary = CollectionSummary(
            kind: .day,
            key: stamps.joined(separator: ".."),
            title: title,
            subtitle: subtitle.compactMap { $0 }.joined(separator: " · "),
            count: run.count,
            // Two: one to show and one to fall back on. Five for every year of
            // every tradition more than doubled the page's response.
            coverAssetIDs: Array(run.days.flatMap(\.coverAssetIDs).prefix(2)),
            isNamed: userName != nil,
            recursAnnually: pattern.source == .date || pattern.source == .named
        )
        return (summary, year, place)
    }

    /// The card a Name or Rename sheet works on, for a date: its latest year
    /// on the date itself, under the tradition's name.
    private func naming(_ pattern: Pattern, cards: [CollectionSummary], title: String) -> CollectionSummary? {
        guard pattern.source == .date || pattern.source == .named, let monthDay = pattern.monthDay,
              let latest = cards.first(where: { $0.key.count == 10 && $0.key.hasSuffix(monthDay) })
        else { return nil }
        return CollectionSummary(
            kind: .day, key: latest.key, title: title, subtitle: latest.subtitle,
            count: latest.count, coverAssetIDs: latest.coverAssetIDs,
            isNamed: pattern.source == .named, recursAnnually: true
        )
    }

    /// When a tradition next comes round, from today on: a holiday by this
    /// year's or next year's table, anything else by its date.
    static func next(_ pattern: Pattern, after today: Int, holidays calendar: [String: String]) -> Int? {
        if case .holiday(let family) = pattern.source {
            return calendar
                .filter { self.family(of: $0.value) == family }
                .compactMap { CivilDay.number($0.key) }
                .filter { $0 >= today }
                .min()
        }
        guard let monthDay = pattern.monthDay, let (month, day) = CivilDay.monthDay(monthDay) else {
            return nil
        }
        let year = CivilDay.civil(today).year
        // Four years ahead covers February 29.
        for candidate in year...(year + 4) where CivilDay.isValid(year: candidate, month: month, day: day) {
            let number = CivilDay.number(year: candidate, month: month, day: day)
            if number >= today { return number }
        }
        return nil
    }
}

/// Dates as day numbers, without a `DateFormatter`.
///
/// The yearly rules look at a month either side of every date that recurs, in
/// every year of a library: a hundred thousand lookups on a large one, where a
/// formatter costs about 85 µs just to make. Days since 1970 by Howard
/// Hinnant's civil-calendar arithmetic are exact for any Gregorian date, and
/// the words are American English, like every other title on the page.
enum CivilDay {
    static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func number(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shifted = (month + 9) % 12                         // March is 0
        let dayOfYear = (153 * shifted + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(_ number: Int) -> (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        switch month {
        case 2:
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            return day <= (leap ? 29 : 28)
        case 4, 6, 9, 11: return day <= 30
        default: return day <= 31
        }
    }

    /// `"2025-04-05"` → its number; nil for anything that isn't a real date.
    static func number(_ stamp: String) -> Int? {
        let bytes = Array(stamp.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              isValid(year: year, month: month, day: day) else { return nil }
        return number(year: year, month: month, day: day)
    }

    /// Today's number, from the phone's date, read in UTC like every date here.
    static func number(of date: Date) -> Int {
        let parts = CollectionsController.utc.dateComponents([.year, .month, .day], from: date)
        return number(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `"2025-04-05"`.
    static func stamp(_ number: Int) -> String {
        let (year, month, day) = civil(number)
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
    }

    /// `"04-05"`.
    static func monthDayStamp(month: Int, day: Int) -> String {
        pad(month, 2) + "-" + pad(day, 2)
    }

    static func monthDayStamp(_ number: Int) -> String {
        let (_, month, day) = civil(number)
        return monthDayStamp(month: month, day: day)
    }

    /// `"04-05"` → (4, 5).
    static func monthDay(_ stamp: String) -> (Int, Int)? {
        let parts = stamp.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
              isValid(year: 2000, month: month, day: day) else { return nil }
        return (month, day)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    // MARK: Words

    /// "April 5".
    static func spoken(month: Int, day: Int) -> String {
        "\(months[month - 1]) \(day)"
    }

    /// "Saturday".
    static func weekday(_ number: Int) -> String {
        weekdays[((number % 7) + 11) % 7]                  // 1970-01-01 was a Thursday
    }

    /// The days a card covers, as `CollectionsController.dateRange` says them:
    /// "April 5, 2025", "May 17–18, 2025", "May 31 – June 1, 2025" and
    /// "December 31, 2024 – January 1, 2025".
    static func range(_ from: Int, _ to: Int) -> String {
        let (y1, m1, d1) = civil(from)
        guard to > from else { return "\(months[m1 - 1]) \(d1), \(y1)" }
        let (y2, m2, d2) = civil(to)
        if y1 == y2, m1 == m2 { return "\(months[m1 - 1]) \(d1)–\(d2), \(y2)" }
        let left = y1 == y2 ? "\(months[m1 - 1]) \(d1)" : "\(months[m1 - 1]) \(d1), \(y1)"
        return "\(left) – \(months[m2 - 1]) \(d2), \(y2)"
    }

    // MARK: The year as a circle

    /// Where a date falls in the year, 0 to 364, on a year without a February
    /// 29: that day sits with the 28th.
    static func position(month: Int, day: Int) -> Int {
        let day = month == 2 ? min(day, 28) : day
        return number(year: 2001, month: month, day: day) - number(year: 2001, month: 1, day: 1)
    }

    /// The month and day at a position.
    static func monthDay(atPosition position: Int) -> (Int, Int) {
        let (_, month, day) = civil(number(year: 2001, month: 1, day: 1) + ((position % 365) + 365) % 365)
        return (month, day)
    }

    static func monthDayStamp(atPosition position: Int) -> String {
        let (month, day) = monthDay(atPosition: position)
        return monthDayStamp(month: month, day: day)
    }

    /// Days between two positions the short way round: December 30 and
    /// January 2 are three days apart.
    static func distance(_ a: Int, _ b: Int) -> Int {
        let gap = abs(a - b) % 365
        return min(gap, 365 - gap)
    }

    /// The middle of some positions, the short way round.
    static func middle(of positions: [Int]) -> Int {
        guard !positions.isEmpty else { return 0 }
        var x = 0.0
        var y = 0.0
        for position in positions {
            let angle = Double(position) / 365 * 2 * .pi
            x += cos(angle)
            y += sin(angle)
        }
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi) * 365).rounded()) % 365
    }

    /// Ascending day numbers in runs of consecutive days.
    static func consecutive(_ numbers: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for number in numbers {
            if let last = runs.last?.last, number == last + 1 {
                runs[runs.count - 1].append(number)
            } else if runs.last?.last != number {
                runs.append([number])
            }
        }
        return runs
    }
}
