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
    /// Several rather than one because the hero cycles through them. The rows
    /// take `coverAssetID` and hold still — eight tiles crossfading at
    /// different offsets is the noise this page exists to avoid, and a rotating
    /// tile costs five thumbnails where a still one costs a single.
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

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(
        kind: CollectionKind, key: String, title: String,
        subtitle: String?, count: Int, coverAssetIDs: [UUID],
        isNamed: Bool = false, recursAnnually: Bool = false
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.coverAssetIDs = coverAssetIDs
        self.isNamed = isNamed
        self.recursAnnually = recursAnnually
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
    public let trips: [CollectionSummary]
    public let days: [CollectionSummary]
    /// Places the library knows well and hasn't seen in years.
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

    /// Spelled out only to hold `favorites` to the key it shipped as — see
    /// `CollectionKind.favorites`. Everything else is its own name.
    enum CodingKeys: String, CodingKey {
        case hero, trips, days, revisits, mediaTypes, recentlyDeleted, recentlyAdded
        case favorites = "favourites"
    }

    public init(
        hero: CollectionSummary?,
        trips: [CollectionSummary],
        days: [CollectionSummary],
        revisits: [CollectionSummary] = [],
        mediaTypes: [CollectionSummary] = [],
        recentlyDeleted: CollectionSummary?,
        recentlyAdded: CollectionSummary? = nil,
        favorites: CollectionSummary? = nil
    ) {
        self.hero = hero
        self.trips = trips
        self.days = days
        self.revisits = revisits
        self.mediaTypes = mediaTypes
        self.recentlyDeleted = recentlyDeleted
        self.recentlyAdded = recentlyAdded
        self.favorites = favorites
    }

    /// Whether the page has anything to *show* — as opposed to anything at all.
    ///
    /// Media types and Recently Deleted are deliberately excluded. They are
    /// always-on utilities rather than things that happened, and counting them
    /// meant a young library rendered as two gray rows over a screen of black
    /// while the page insisted it wasn't empty. A library of scans with no
    /// dates and no coordinates legitimately has none of this, and deserves to
    /// be told so.
    public var isEmpty: Bool {
        hero == nil && trips.isEmpty && days.isEmpty && revisits.isEmpty
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
