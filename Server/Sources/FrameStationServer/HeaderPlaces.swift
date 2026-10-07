import Foundation

/// What a day's or month's header calls the places its photos were taken.
///
/// It used to be the single commonest place, which hid every other one. Two
/// family members sharing a day from two cities showed up under whichever
/// city had more photos, and so did one person's day trip. Now places close
/// together count as one, named after where most of their photos were.
///
/// A day spent in several of those names the first one it visited, in full,
/// beside its date, and every later one gets its own line where its photos
/// start (see `group`). It used to put them all beside the date — "Reston and
/// Richmond" — and with each of them also heading its own photos, the day said
/// everything twice. A month or a year still names the places it was mostly
/// spent, "Reston, Richmond and 1 more": it has no lines of its own to do it.
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
        /// Every place merged into it, its own name included.
        var places: Set<String> = []
    }

    /// A day's header: where it went first, in full. See the type's note.
    static func dayLabel(_ places: [Place]) -> String? {
        areas(places, order: .time).first?.name
    }

    /// A month's or year's header text for these places, or nil when none of
    /// the photos has one.
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
                areas[joins].places.insert(place.name)
            } else {
                areas.append(Area(
                    name: place.name, count: place.count, first: place.first,
                    latitude: place.latitude, longitude: place.longitude,
                    places: [place.name]
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

    // MARK: - A day, photo by photo

    /// One photo of a day, as grouping it by area needs it.
    struct DayPhoto {
        /// `space_assets.id`, the same as `TimelineItem.id`.
        let id: UUID
        let place: String?
        let latitude: Double?
        let longitude: Double?
        /// Who took it, or who it's credited to.
        let contributor: UUID
        let at: Date
    }

    /// A day's photos grouped by area: the areas in the order the day visited
    /// them, each with its full name and photo count, and which area each
    /// photo belongs to.
    struct DayGroups {
        let areas: [(name: String, count: Int)]
        let areaOf: [UUID: Int]
        /// The day's header text: the first area, in full. The rest are named
        /// on lines of their own, from `areas`.
        let label: String?
    }

    /// Groups a day's photos by area.
    ///
    /// A photo with a place joins that place's area. One without, such as a
    /// screenshot or a file imported with no location, joins the area of the
    /// same person's photo taken closest in time. Failing that, the day's
    /// closest photo of anyone's. It never borrows another family member's
    /// city when its own person's photos say where they were.
    static func group(_ photos: [DayPhoto]) -> DayGroups {
        var byName: [String: (count: Int, latitude: Double, longitude: Double, located: Int, first: Date)] = [:]
        for photo in photos {
            guard let name = photo.place else { continue }
            var entry = byName[name] ?? (0, 0, 0, 0, photo.at)
            entry.count += 1
            if let lat = photo.latitude, let lon = photo.longitude {
                entry.latitude += lat
                entry.longitude += lon
                entry.located += 1
            }
            entry.first = min(entry.first, photo.at)
            byName[name] = entry
        }
        let places = byName.map { name, entry in
            Place(
                name: name, count: entry.count,
                latitude: entry.located > 0 ? entry.latitude / Double(entry.located) : nil,
                longitude: entry.located > 0 ? entry.longitude / Double(entry.located) : nil,
                first: entry.first
            )
        }
        let ordered = areas(places, order: .time)
        let label = ordered.first?.name

        var areaOfPlace: [String: Int] = [:]
        for (index, area) in ordered.enumerated() {
            for name in area.places { areaOfPlace[name] = index }
        }

        var areaOf: [UUID: Int] = [:]
        let placed = photos.filter { $0.place != nil }.sorted { $0.at < $1.at }
        for photo in placed {
            if let name = photo.place, let index = areaOfPlace[name] { areaOf[photo.id] = index }
        }
        if !placed.isEmpty {
            for photo in photos where photo.place == nil {
                let own = placed.filter { $0.contributor == photo.contributor }
                let nearest = (own.isEmpty ? placed : own).min {
                    abs($0.at.timeIntervalSince(photo.at)) < abs($1.at.timeIntervalSince(photo.at))
                }
                if let nearest, let index = areaOf[nearest.id] { areaOf[photo.id] = index }
            }
        }

        var counts = Array(repeating: 0, count: ordered.count)
        for index in areaOf.values { counts[index] += 1 }
        return DayGroups(
            areas: zip(ordered, counts).map { (name: $0.name, count: $1) },
            areaOf: areaOf,
            label: label
        )
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
