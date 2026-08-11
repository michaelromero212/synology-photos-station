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

public struct PlacesResponse: Codable, Sendable, Hashable {
    public let places: [PlaceSummary]

    public init(places: [PlaceSummary]) {
        self.places = places
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
