import Foundation

/// One place the library has photos from, and how many.
///
/// Place names are already computed at import by the offline geocoder, so this
/// is a `GROUP BY` over a column we hold rather than anything new — which is
/// why search starts here rather than with tags. Every photo carrying GPS has
/// a place from the moment it lands; tags only exist where somebody typed one.
public struct PlaceSummary: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let count: Int

    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The places a space has photos from.
///
/// `places` is a *page*, not the whole vocabulary. A library accumulates one
/// entry per town anyone ever passed through, so the honest shape here is a
/// bounded list plus a count of what was left out — the caller decides whether
/// it wants the handful worth showing on a landing screen or the lot.
/// Something photos in a library were seen to show, for the search screen:
/// what a person's own devices recognized, with how many photos show it.
public struct ThingSummary: Codable, Sendable, Hashable, Identifiable {
    /// What to search for, as the server stores it: `"birthday_cake"`.
    public let term: String
    /// How to say it: "Birthday cake".
    public let name: String
    public let count: Int

    public var id: String { term }

    public init(term: String, name: String, count: Int) {
        self.term = term
        self.name = name
        self.count = count
    }
}

public struct ThingsResponse: Codable, Sendable, Hashable {
    /// Commonest first.
    public let things: [ThingSummary]
    /// How many distinct things match, whatever `things` holds.
    public let total: Int

    public init(things: [ThingSummary], total: Int) {
        self.things = things
        self.total = total
    }
}

public struct PlacesResponse: Codable, Sendable, Hashable {
    public let places: [PlaceSummary]
    /// How many distinct places exist in total, whatever `places` holds. What
    /// lets a "See All" row say how many it is offering.
    public let total: Int

    public init(places: [PlaceSummary], total: Int) {
        self.places = places
        self.total = total
    }
}

/// A page of search results.
///
/// Flat and date-ordered rather than bucketed like the timeline: a result set
/// is not a library, and imposing day sections on eleven photos from four years
/// would be more chrome than content.
public struct SearchResults: Codable, Sendable, Hashable {
    public let items: [TimelineItem]
    /// Matches in total, not in this page — so the screen can say "247 photos"
    /// without fetching them all.
    public let total: Int
    /// Where to resume, or nil at the end.
    public let nextOffset: Int?

    public init(items: [TimelineItem], total: Int, nextOffset: Int?) {
        self.items = items
        self.total = total
        self.nextOffset = nextOffset
    }
}

/// One search the search screen offers before anything is typed.
public struct SearchSuggestion: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case place, thing, year

        /// A kind this app doesn't know yet searches as text, which every
        /// kind can.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .thing
        }
    }

    public let kind: Kind
    /// What the chip says: "Linton Hall".
    public let title: String
    /// What it searches for: "Linton Hall, Virginia". A place's is a place
    /// name; everything else's is searched as typed text.
    public let query: String

    public var id: String { "\(kind.rawValue)|\(query)" }

    public init(kind: Kind, title: String, query: String) {
        self.kind = kind
        self.title = title
        self.query = query
    }
}

public struct SearchSuggestionsResponse: Codable, Sendable, Hashable {
    /// Places first, then things, then a year.
    public let suggestions: [SearchSuggestion]
    /// Whether what's in a photo can be searched for, which it can't for
    /// someone who has turned off recognizing it.
    public let recognizesContent: Bool

    public init(suggestions: [SearchSuggestion], recognizesContent: Bool) {
        self.suggestions = suggestions
        self.recognizesContent = recognizesContent
    }
}
