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
    /// The photo to draw on the card. Nil only when the collection is empty,
    /// which the page treats as a reason not to show it at all.
    public let coverAssetID: UUID?

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(
        kind: CollectionKind, key: String, title: String,
        subtitle: String?, count: Int, coverAssetID: UUID?
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.coverAssetID = coverAssetID
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
    /// Present only for a personal space, and only when something is in it.
    public let recentlyDeleted: CollectionSummary?

    public init(
        hero: CollectionSummary?,
        trips: [CollectionSummary],
        days: [CollectionSummary],
        recentlyDeleted: CollectionSummary?
    ) {
        self.hero = hero
        self.trips = trips
        self.days = days
        self.recentlyDeleted = recentlyDeleted
    }

    /// Whether the page has anything automatic to show at all. A library of
    /// scans with no dates and no coordinates legitimately has none of this,
    /// and should fall back to manual albums rather than to empty headings.
    public var isEmpty: Bool {
        hero == nil && trips.isEmpty && days.isEmpty && recentlyDeleted == nil
    }
}
