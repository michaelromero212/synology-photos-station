import Foundation

/// What a day's or month's header calls the places its photos were taken.
///
/// It used to be the single commonest place, which hid every other one. Two
/// family members sharing a day from two cities showed up under whichever
/// city had more photos, and so did one person's day trip. Now places close
/// together count as one, named after where most of their photos were, and
/// places farther apart are all named: "Reston and Richmond", or "Reston,
/// Richmond and 1 more".
enum HeaderPlaces {
    /// One named place among a bucket's photos.
    struct Place {
        let name: String
        let count: Int
        /// The average position of its photos, when they have one.
        let latitude: Double?
        let longitude: Double?
        /// When its first photo was taken.
        let first: Date?
    }

    /// How the places in a header are ordered.
    enum Order {
        /// In the order they were first visited: a day reads as it happened.
        case time
        /// Where most photos were first: a month leads with where it was
        /// mostly spent.
        case count
    }

    /// Places closer than this to a bigger one count as part of it. About 15
    /// miles: a day of errands around neighboring towns stays one place, and a
    /// trip to the next city doesn't.
    static let sameAreaMeters = 24_000.0

    /// A group of nearby places, named after the one with the most photos.
    struct Area {
        var name: String
        var count: Int
        var first: Date?
        let latitude: Double?
        let longitude: Double?
    }

    /// The header text for these places, or nil when none of the photos has
    /// one.
    static func label(_ places: [Place], order: Order) -> String? {
        let ordered = areas(places, order: order)
        guard let lead = ordered.first else { return nil }
        guard ordered.count > 1 else { return lead.name }

        // Town names alone once there's more than one: the full names don't
        // fit a header line. Unless two towns share a name, when the region
        // is what tells them apart.
        let named = ordered.prefix(2).map(\.name)
        var shown = named.map(town)
        if Set(shown).count < shown.count { shown = named }

        if ordered.count == 2 { return "\(shown[0]) and \(shown[1])" }
        return "\(shown[0]), \(shown[1]) and \(ordered.count - 2) more"
    }

    /// Nearby places merged, in `order`.
    ///
    /// Each area grows from its biggest place outward rather than by chaining
    /// neighbor to neighbor, so a long drive with a stop every few miles can't
    /// stretch one area across a whole state.
    static func areas(_ places: [Place], order: Order) -> [Area] {
        let biggestFirst = places.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name
        }
        var areas: [Area] = []
        for place in biggestFirst {
            let joins = areas.firstIndex { area in
                guard let aLat = area.latitude, let aLon = area.longitude,
                      let lat = place.latitude, let lon = place.longitude
                else { return false }
                return distance(aLat, aLon, lat, lon) <= sameAreaMeters
            }
            if let joins {
                areas[joins].count += place.count
                areas[joins].first = earliest(areas[joins].first, place.first)
            } else {
                areas.append(Area(
                    name: place.name, count: place.count, first: place.first,
                    latitude: place.latitude, longitude: place.longitude
                ))
            }
        }

        switch order {
        case .count:
            return areas.sorted {
                $0.count != $1.count ? $0.count > $1.count : earlier($0.first, $1.first)
            }
        case .time:
            return areas.sorted {
                $0.first != $1.first ? earlier($0.first, $1.first) : $0.count > $1.count
            }
        }
    }

    /// "Reston" from "Reston, Virginia".
    static func town(_ name: String) -> String {
        name.split(separator: ",", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    /// Great-circle distance in meters.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return min(a, b)
    }

    /// Whether `a` comes before `b`, an unknown time last.
    private static func earlier(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return a < b
        case (_?, nil): return true
        default: return false
        }
    }
}
