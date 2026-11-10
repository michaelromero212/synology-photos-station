import Foundation

/// What kind of thing a collection is, and therefore how to open it.
///
/// Deliberately a closed set rather than free-form strings: the app switches on
/// this to decide a title style and a destination, and a typo in a string would
/// be a silently missing screen rather than a build error.
public enum CollectionKind: String, Codable, Sendable, Hashable {
    /// The same calendar day in an earlier year.
    case onThisDay
    /// A run of days spent away from home.
    case trip
    /// A single day with far more photos than usual.
    case day
    /// Removed from a personal space and still recoverable.
    case recentlyDeleted
    /// This week, in the year you were somewhere else.
    case anniversary
    /// Somewhere the library hasn't been in years.
    case revisit
    /// A whole season, looked back on.
    case season
    /// Everything of one shape — videos, panoramas, bursts.
    case mediaType
    /// What reached the library lately, by *arrival* rather than by when it was
    /// taken. The one question a backup app is asked constantly — "did my phone
    /// put my photos somewhere safe" — and the only collection here that
    /// answers it, because every other one is ordered by the past.
    case recentlyAdded
    /// The ones this person reached over and marked. Not computed at all, and
    /// that is the point of it: everything else here is the library's opinion,
    /// and this is theirs.
    ///
    /// The wire keeps the spelling it shipped with, and that is not an oversight
    /// — `CollectionSummary.kind` is not optional, so a deployed server sending
    /// `"favourites"` to a client that only knows `"favorites"` does not lose one
    /// shelf, it fails to decode the Albums page entirely. Pinning the raw value
    /// lets the Swift read like the rest of the codebase without that mattering.
    /// It becomes a one-word change the day the server and the app ship together.
    case favorites = "favourites"
    /// Everyone the NAS found as one person in the owner's library, keyed by
    /// the person's id. Older apps skip a kind they don't know.
    case person
    /// The photos two people are both in, keyed "id,id". See
    /// `PeopleTogether`.
    case together
}

/// One entry on the Albums page: enough to draw a card, and a key to open it.
///
/// The count is here because a collection worth showing is one worth sizing —
/// and because the page's rule is that anything thin doesn't get a row, which
/// cannot be decided without it.
public struct CollectionSummary: Codable, Sendable, Hashable, Identifiable {
    public let kind: CollectionKind
    /// Opaque to the app, meaningful to the server: the year for On This Day,
    /// a date for a day, a date range for a trip. Passed straight back to fetch
    /// the contents, so the app never has to know how a collection is defined.
    public let key: String
    public let title: String
    /// The line under the title — dates, place, count. Nil where the title says
    /// everything.
    public let subtitle: String?
    public let count: Int
    /// The photographs worth putting on the card, best first.
    ///
    /// Several rather than one so a card whose first choice can't be drawn has
    /// the next to fall back on. Only one is ever shown, and it holds still —
    /// the hero used to crossfade through these, and motion on the card at the
    /// top of the page read as the page not having finished arriving.
    public let coverAssetIDs: [UUID]

    /// The one to use where only one is wanted.
    public var coverAssetID: UUID? { coverAssetIDs.first }
    /// True when `title` is what somebody typed rather than what the library
    /// worked out. Lets the card offer "Rename" instead of "Name this", and
    /// lets it offer to take the name back off again.
    public let isNamed: Bool
    /// Whether the same date is busy in several earlier years.
    ///
    /// The app can't know a date is a birthday, but it can notice you have
    /// photographs on it most years — which is exactly when "name this every
    /// year" is the offer worth making rather than a question out of nowhere.
    public let recursAnnually: Bool
    /// Why this card is the one on top today, in the server's words —
    /// "CHRISTMAS IS COMING UP" — where the kind alone can't say. Nil for the
    /// app's own line for the kind.
    ///
    /// Optional so a server that predates it, and a client that ignores it,
    /// both carry on.
    public let kicker: String?
    /// The `Tradition.id` this card is a year of, where it's one: Christmas
    /// 2023 is a year of "holiday:Christmas". A page that shows Over the
    /// Years leaves these out of Holidays & Occasions, which then holds what
    /// happened once, and the same photos aren't on the page twice.
    ///
    /// Optional, so an app that predates Over the Years ignores it and keeps
    /// every card where it always was.
    public let tradition: String?

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(
        kind: CollectionKind, key: String, title: String,
        subtitle: String?, count: Int, coverAssetIDs: [UUID],
        isNamed: Bool = false, recursAnnually: Bool = false,
        kicker: String? = nil, tradition: String? = nil
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.coverAssetIDs = coverAssetIDs
        self.isNamed = isNamed
        self.recursAnnually = recursAnnually
        self.kicker = kicker
        self.tradition = tradition
    }

    /// The same card with a different line above its title.
    public func withKicker(_ kicker: String?) -> CollectionSummary {
        CollectionSummary(
            kind: kind, key: key, title: title, subtitle: subtitle, count: count,
            coverAssetIDs: coverAssetIDs, isNamed: isNamed,
            recursAnnually: recursAnnually, kicker: kicker, tradition: tradition
        )
    }

    /// The same card, as a year of `tradition`.
    public func inTradition(_ tradition: String?) -> CollectionSummary {
        CollectionSummary(
            kind: kind, key: key, title: title, subtitle: subtitle, count: count,
            coverAssetIDs: coverAssetIDs, isNamed: isNamed,
            recursAnnually: recursAnnually, kicker: kicker, tradition: tradition
        )
    }

    /// The same card under another title: whose birthday it was, say.
    public func withTitle(_ title: String) -> CollectionSummary {
        CollectionSummary(
            kind: kind, key: key, title: title, subtitle: subtitle, count: count,
            coverAssetIDs: coverAssetIDs, isNamed: isNamed,
            recursAnnually: recursAnnually, kicker: kicker, tradition: tradition
        )
    }

    /// The same card with another line under its title: who was there, say.
    public func withSubtitle(_ subtitle: String?) -> CollectionSummary {
        CollectionSummary(
            kind: kind, key: key, title: title, subtitle: subtitle, count: count,
            coverAssetIDs: coverAssetIDs, isNamed: isNamed,
            recursAnnually: recursAnnually, kicker: kicker, tradition: tradition
        )
    }
}

// MARK: - Naming an occasion

/// Gives a day a name, or takes the name away.
///
/// `everyYear` is the whole of the birthday-versus-party distinction: a
/// birthday is this date in every year, an engagement party is this date once.
/// One answer in a sheet rather than two separate features.
public struct NameOccasionRequest: Codable, Sendable, Hashable {
    /// The day being named, `YYYY-MM-DD`. For a run of days it is the first.
    public let day: String
    /// Nil clears whichever name applies.
    public let name: String?
    public let everyYear: Bool

    public init(day: String, name: String?, everyYear: Bool) {
        self.day = day
        self.name = name
        self.everyYear = everyYear
    }
}

/// The whole Albums page in one request.
///
/// One call rather than one per section, because the page is a front page: it
/// has to decide what the hero *is* before it can draw anything, and that
/// decision depends on what every section found. Six round trips to answer one
/// question would also mean six chances for the page to appear in pieces.
public struct CollectionsResponse: Codable, Sendable, Hashable {
    /// The single thing worth looking at today, already chosen. On This Day
    /// when there is one, otherwise the most recent trip — the app draws
    /// whatever it is given rather than re-deciding.
    public let hero: CollectionSummary?
    /// The few trips worth a row on the page — never every trip. See
    /// `allTrips` for the rest.
    public let trips: [CollectionSummary]
    /// The few holidays and occasions worth a row on the page. The field keeps
    /// the name it shipped with, from when it held busy days.
    public let days: [CollectionSummary]
    /// Places the library knows well and hasn't seen in years. Empty from
    /// servers that offer these only as the hero.
    public let revisits: [CollectionSummary]
    /// Videos, panoramas, bursts and the rest — the file-shaped things.
    ///
    /// One row on the page, not twelve. Apple gives these a section each and
    /// the result is a filing cabinet; they are a filter, and a filter belongs
    /// behind a single door.
    public let mediaTypes: [CollectionSummary]
    /// Present only for a personal space, and only when something is in it.
    public let recentlyDeleted: CollectionSummary?
    /// What arrived lately. Its own field rather than a member of any array
    /// above, and that is a deployment decision as much as a shape one: a
    /// client that predates this ignores a JSON key it does not know, so it
    /// never meets the `recentlyAdded` case and never fails to decode the page.
    /// Put inside `days`, one new enum case would have emptied the Albums tab
    /// on every device that hadn't been rebuilt yet.
    public let recentlyAdded: CollectionSummary?
    /// What this person has marked, in this space. Per-user by construction —
    /// two people looking at the same shared album see their own.
    ///
    /// Its own field for the same reason as `recentlyAdded`: an older client
    /// ignores a key it doesn't know and so never meets the new kind.
    public let favorites: CollectionSummary?
    /// Every trip the library found, newest first — what "See All" opens.
    /// `trips` is a few chosen from these.
    ///
    /// Optional, and its own field, for the same reason as `recentlyAdded`: an
    /// older client ignores it, and a newer one talking to an older server
    /// finds nil and simply offers no "See All".
    public let allTrips: [CollectionSummary]?
    /// Every holiday and occasion, newest first — what "See All" opens under
    /// `days`.
    public let allOccasions: [CollectionSummary]?
    /// The row of cards the page opens on, to swipe through: what's tied to
    /// today, a featured photo or two, then the day's highlights. `hero` is
    /// its first card, for apps that draw only one. Nil from an older server.
    public let featured: [CollectionSummary]?
    /// What comes round every year, the soonest first: each Christmas
    /// together, a day somebody named, a date photographed most years. The
    /// page's Over the Years.
    ///
    /// Optional and its own field, like `allTrips`: an older app ignores a
    /// key it doesn't know, and a newer one talking to an older server finds
    /// nil and draws no section. Empty means the server looked and found
    /// nothing yet.
    public let traditions: [Tradition]?
    /// The trips a page with room for a whole row of them shows, as the
    /// Mac's: `trips` by the same rules, up to twelve, newest first.
    ///
    /// Optional, like `allTrips`: an older app ignores it, and a newer one
    /// talking to an older server finds nil and shows `trips`.
    public let wideTrips: [CollectionSummary]?
    /// Holidays & Occasions for an app that shows Over the Years: what
    /// happened once, chosen by `days`' rules but leaving out every year of a
    /// tradition, up to twelve, newest first. The phone takes the first few,
    /// the Mac a row. Nil from an older server; `days` is then the section.
    public let wideDays: [CollectionSummary]?
    /// The people in the owner's library, for someone the NAS analyzes: the
    /// named first, then the rest by how many photos they're in. Optional
    /// and its own field, like `traditions`: older apps ignore it, and a
    /// newer one talking to an older server, or anyone else's library, finds
    /// nil and draws no People row.
    public let people: [PersonSummary]?
    /// People often in the same photos, the most first. Optional and its own
    /// field, like `people`.
    public let together: [PeopleTogether]?

    /// Spelled out only to hold `favorites` to the key it shipped as — see
    /// `CollectionKind.favorites`. Everything else is its own name.
    enum CodingKeys: String, CodingKey {
        case hero, trips, days, revisits, mediaTypes, recentlyDeleted, recentlyAdded
        case favorites = "favourites"
        case allTrips, allOccasions, featured, traditions, wideTrips, wideDays, people, together
    }

    /// Read card by card, so a card this build can't read is left out instead
    /// of failing the whole page.
    ///
    /// `CollectionSummary.kind` is a closed set, and the synthesized decoder
    /// threw on a single unknown value — the hero and every shelf gone, on any
    /// device still running an older build. Curated albums will bring new
    /// kinds, and the family's devices update when they update, so this has to
    /// reach all of them first. A newer server then costs an older app the
    /// cards it doesn't understand, never the page.
    ///
    /// A missing array reads as empty for the same reason. Encoding is still
    /// synthesized, so what the server sends doesn't change.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func card(_ key: CodingKeys) -> CollectionSummary? {
            try? container.decodeIfPresent(CollectionSummary.self, forKey: key)
        }
        func cards(_ key: CodingKeys) -> [CollectionSummary]? {
            (try? container.decodeIfPresent([Skippable<CollectionSummary>].self, forKey: key))?
                .map { $0.compactMap(\.value) }
        }
        hero = card(.hero)
        trips = cards(.trips) ?? []
        days = cards(.days) ?? []
        revisits = cards(.revisits) ?? []
        mediaTypes = cards(.mediaTypes) ?? []
        recentlyDeleted = card(.recentlyDeleted)
        recentlyAdded = card(.recentlyAdded)
        favorites = card(.favorites)
        allTrips = cards(.allTrips)
        allOccasions = cards(.allOccasions)
        featured = cards(.featured)
        // One by one too, so a tradition this build can't read costs that
        // tradition and not the section.
        traditions = (try? container.decodeIfPresent([Skippable<Tradition>].self, forKey: .traditions))?
            .map { $0.compactMap(\.value) }
        wideTrips = cards(.wideTrips)
        wideDays = cards(.wideDays)
        people = (try? container.decodeIfPresent([Skippable<PersonSummary>].self, forKey: .people))?
            .map { $0.compactMap(\.value) }
        together = (try? container.decodeIfPresent([Skippable<PeopleTogether>].self, forKey: .together))?
            .map { $0.compactMap(\.value) }
    }

    public init(
        hero: CollectionSummary?,
        trips: [CollectionSummary],
        days: [CollectionSummary],
        revisits: [CollectionSummary] = [],
        mediaTypes: [CollectionSummary] = [],
        recentlyDeleted: CollectionSummary?,
        recentlyAdded: CollectionSummary? = nil,
        favorites: CollectionSummary? = nil,
        allTrips: [CollectionSummary]? = nil,
        allOccasions: [CollectionSummary]? = nil,
        featured: [CollectionSummary]? = nil,
        traditions: [Tradition]? = nil,
        wideTrips: [CollectionSummary]? = nil,
        wideDays: [CollectionSummary]? = nil,
        people: [PersonSummary]? = nil,
        together: [PeopleTogether]? = nil
    ) {
        self.people = people
        self.together = together
        self.featured = featured
        self.traditions = traditions
        self.wideTrips = wideTrips
        self.wideDays = wideDays
        self.hero = hero
        self.trips = trips
        self.days = days
        self.revisits = revisits
        self.mediaTypes = mediaTypes
        self.recentlyDeleted = recentlyDeleted
        self.recentlyAdded = recentlyAdded
        self.favorites = favorites
        self.allTrips = allTrips
        self.allOccasions = allOccasions
    }

    /// Holidays & Occasions' full list for an app that shows Over the Years:
    /// `allOccasions` without the years of a tradition, which are under its
    /// card. Everything, from a server that sends no traditions.
    public var onceOccasions: [CollectionSummary]? {
        guard traditions != nil else { return allOccasions }
        return allOccasions?.filter { $0.tradition == nil }
    }

    /// Holidays & Occasions on the page: what happened once, newest first,
    /// at most `limit`. A server that sends no traditions chose `days`.
    public func onceDays(limit: Int) -> [CollectionSummary] {
        guard traditions != nil, let wideDays else { return days }
        return Array(wideDays.prefix(limit))
    }

    /// Whether the page has anything to *show* — as opposed to anything at all.
    ///
    /// Media types and Recently Deleted are deliberately excluded. They are
    /// always-on utilities rather than things that happened, and counting them
    /// meant a young library rendered as two gray rows over a screen of black
    /// while the page insisted it wasn't empty. A library of scans with no
    /// dates and no coordinates legitimately has none of this, and deserves to
    /// be told so.
    ///
    /// People count. They're something the library found, like a trip, and
    /// a library young enough to have no trips yet may well have people.
    public var isEmpty: Bool {
        hero == nil && trips.isEmpty && days.isEmpty && revisits.isEmpty
            && (people?.isEmpty ?? true)
    }
}

// MARK: - Over the Years

/// Something that comes round every year, with each year of it: Christmas, a
/// day somebody named, the date a library is photographed most years, the
/// party held about the same week every spring.
///
/// Its own type rather than one more `CollectionSummary`, because it doesn't
/// open onto photos. It opens onto its years, and each of those is an
/// ordinary collection that opens the way every card on the page does.
public struct Tradition: Codable, Sendable, Hashable, Identifiable {
    /// Holds still while the tradition is found — "holiday:Christmas",
    /// "date:04-05" — so a screen showing one finds it again after the page
    /// refreshes, and still finds it once the date has been given a name.
    public let id: String
    public let title: String
    /// "9 years · 2016–2025".
    public let subtitle: String?
    /// Every photo across its years.
    public let count: Int
    /// A photo from one of its years, a different year each day, best first.
    public let coverAssetIDs: [UUID]
    /// Each year of it, oldest first (newest first before November 2026):
    /// the latest 25, read as a story. Kind `.day`, keyed by its days, or
    /// `.trip` for a trip taken every year, so each opens on its own photos.
    public let years: [CollectionSummary]
    /// When it next comes round, `YYYY-MM-DD`. The server already lists the
    /// soonest first; this is for saying so.
    public let next: String?
    /// The card a Name or Rename sheet works on, where the tradition is a date
    /// the person can call what it is: one the library found, or one they've
    /// already named. Nil for a holiday or an event, which have their names.
    public let naming: CollectionSummary?

    /// The one to use where only one is wanted.
    public var coverAssetID: UUID? { coverAssetIDs.first }

    public init(
        id: String, title: String, subtitle: String?, count: Int, coverAssetIDs: [UUID],
        years: [CollectionSummary], next: String? = nil, naming: CollectionSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.coverAssetIDs = coverAssetIDs
        self.years = years
        self.next = next
        self.naming = naming
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, count, coverAssetIDs, years, next, naming
    }

    /// Year by year, as the page reads its cards: a year this build can't
    /// read is left out rather than the tradition, and anything optional that
    /// isn't there reads as absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = (try? container.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        count = ((try? container.decodeIfPresent(Int.self, forKey: .count)) ?? nil) ?? 0
        coverAssetIDs = ((try? container.decodeIfPresent([UUID].self, forKey: .coverAssetIDs)) ?? nil) ?? []
        years = ((try? container.decodeIfPresent([Skippable<CollectionSummary>].self, forKey: .years)) ?? nil)?
            .compactMap(\.value) ?? []
        next = (try? container.decodeIfPresent(String.self, forKey: .next)) ?? nil
        naming = (try? container.decodeIfPresent(CollectionSummary.self, forKey: .naming)) ?? nil
    }
}

/// One element of an array that may hold things this build can't read: the
/// value, or nil in its place.
///
/// Going through `singleValueContainer` rather than calling `Value(from:)`
/// keeps the decoder's own strategies, such as how dates are read.
private struct Skippable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// Puts removed photographs back where they were.
public struct RestoreAssetsRequest: Codable, Sendable, Hashable {
    public let assetIDs: [UUID]

    public init(assetIDs: [UUID]) {
        self.assetIDs = assetIDs
    }
}

/// Deletes removed photographs immediately, ahead of the 29-day sweep — the
/// "Delete Permanently" action in Recently Deleted. Separate from
/// `RestoreAssetsRequest` despite the identical shape, because a request that
/// destroys bytes and one that puts them back should never be confused for each
/// other at a call site.
public struct PurgeAssetsRequest: Codable, Sendable, Hashable {
    public let assetIDs: [UUID]

    public init(assetIDs: [UUID]) {
        self.assetIDs = assetIDs
    }
}
