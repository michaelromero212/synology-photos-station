import Foundation
import Logging

/// Offline reverse geocoding against a trimmed GeoNames dataset.
///
/// Turns `38.3487, -77.9797` into `Culpeper, Virginia` so timeline day headers
/// and the Information panel map read like places rather than numbers.
///
/// Deliberately offline. The alternative is one geocoding API request per photo
/// — 100,000 requests carrying the family's complete location history to a third
/// party. This keeps every coordinate on the NAS and costs nothing per lookup.
///
/// A city's neighborhoods are named for the city. The dataset lists Times
/// Square, Paris's 16th arrondissement and Rome's Celio as places of their
/// own, so a photo by the Eiffel Tower came out as "Paris 16 Passy" and a week
/// in Paris as "Five days in Île-de-France", the region, because no one of its
/// pieces held enough of the week to name it. See `foldNeighborhoods`.
///
/// Data: GeoNames cities1000 and its country table, CC BY 4.0. Built by
/// `Scripts/fetch-geonames.sh`.
final class Geocoder: @unchecked Sendable {
    /// Bump when the same coordinates would be named differently, and every
    /// stored photo is named again on the next boot. See `PlaceFiling`.
    ///
    /// 2: neighborhoods take their city's name, and a region that only
    /// repeats its town's name is left off.
    static let version = 2

    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String
        /// Region name already resolved, e.g. `Virginia` rather than `VA`.
        let region: String?
        /// GeoNames' feature code: `PPLX` is a section of a populated place,
        /// `PPLC` a country's capital.
        let feature: String
        /// Where the place sits in the country's divisions: its country and
        /// admin1 to admin4 codes, each ended with a dot and without trailing
        /// blanks, `US.NY.061.`. One division holds another exactly when its
        /// codes start the other's. A string rather than an array, which for
        /// most places is short enough to be kept inline, so loading 170,000
        /// of them allocates nothing for it.
        let divisions: String
        /// How many codes `divisions` has.
        let depth: Int
        /// The first three: country, state and county.
        let county: String
        let population: Int
        /// The city this place is part of, where it is one of the city's
        /// neighborhoods.
        var city: String?
        /// The country's name, for a place with no region to name.
        var countryName: String?

        /// `Culpeper, Virginia`, and `Paris, Île-de-France` for anywhere in
        /// Paris. A region that only repeats the town is left off: `Tokyo`,
        /// not `Tokyo, Tokyo`.
        var label: String {
            let town = city ?? name
            let after = region.flatMap { $0.isEmpty ? nil : $0 } ?? countryName ?? country
            if after.isEmpty || after == town { return town }
            return "\(town), \(after)"
        }
    }

    private var places: [Place] = []
    /// Whole-degree cell → indices into `places`. Turns a 170k-row scan into a
    /// few dozen distance checks.
    private var grid: [Int: [Int]] = [:]

    /// ISO code → the country's name and its continent's code.
    private var countries: [String: (name: String, continent: String)] = [:]
    /// Region name → the country it is in, for telling a trip abroad.
    private var countryOfRegion: [String: String] = [:]
    /// Labels with no region to say where they are (`Tokyo`) → their country.
    private var countryOfLabel: [String: String] = [:]
    /// A country's name, as a label ends with it → its code.
    private var countryOfName: [String: String] = [:]

    private(set) var isLoaded = false
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Loading

    /// Returns false when the dataset isn't present. That is not an error —
    /// geocoding is optional and `place_name` simply stays null, which the
    /// clients already handle by falling back to raw coordinates.
    ///
    /// An older dataset of five columns still loads, without the extra
    /// columns that tell a neighborhood from a town, so its neighborhoods keep
    /// their own names.
    @discardableResult
    func load(directory: String) -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let citiesURL = root.appendingPathComponent("cities.tsv")
        let adminURL = root.appendingPathComponent("admin1.tsv")
        let countriesURL = root.appendingPathComponent("countries.tsv")

        guard let cities = try? Data(contentsOf: citiesURL) else {
            logger.info("no geonames dataset at \(directory) — place names disabled")
            return false
        }

        // "US" -> "VA" -> "Virginia", two levels so a place's region is found
        // without building "US.VA" for each of 170,000 places.
        var regions: [String: [String: String]] = [:]
        var countryOfRegion: [String: String] = [:]
        if let adminText = try? String(contentsOf: adminURL, encoding: .utf8) {
            for line in adminText.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                let code = parts.first?.split(separator: ".", maxSplits: 1) ?? []
                guard parts.count >= 2, code.count == 2 else { continue }
                let name = String(parts[1])
                regions[String(code[0]), default: [:]][String(code[1])] = name
                if countryOfRegion[name] == nil { countryOfRegion[name] = String(code[0]) }
            }
        }

        // "IT<TAB>Italy<TAB>EU"
        var countries: [String: (name: String, continent: String)] = [:]
        if let text = try? String(contentsOf: countriesURL, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count >= 3 {
                    countries[String(parts[0])] = (String(parts[1]), String(parts[2]))
                }
            }
        }

        // The name each place with no region of its own shows instead, once
        // per country rather than once per place.
        let countryNames = countries.mapValues(\.name)

        var loaded: [Place] = []
        loaded.reserveCapacity(180_000)
        // The columns that hold the country and admin1 to admin4 codes.
        let levels = [3, 4, 6, 7, 8]

        // Read byte by byte: splitting 170,000 lines into Strings field by
        // field was most of what loading cost, and only a few fields are kept.
        Self.eachRow(of: cities) { field in
            guard field.count >= 5,
                  let latitude = Double(field.text(1)),
                  let longitude = Double(field.text(2))
            else { return }
            var depth = levels.count
            while depth > 0, field.isEmpty(levels[depth - 1]) { depth -= 1 }
            var divisions = ""
            var county = ""
            for (level, index) in levels.prefix(depth).enumerated() {
                divisions += field.text(index)
                divisions += "."
                if level == min(depth, 3) - 1 { county = divisions }
            }
            let country = field.text(3)
            loaded.append(
                Place(
                    name: field.text(0),
                    latitude: latitude,
                    longitude: longitude,
                    country: country,
                    region: regions[country]?[field.text(4)],
                    feature: field.text(5),
                    divisions: divisions,
                    depth: depth,
                    county: county,
                    population: field.integer(9),
                    countryName: countryNames[country]
                )
            )
        }

        places = loaded
        grid = [:]
        for (index, place) in loaded.enumerated() {
            grid[Self.cell(place.latitude, place.longitude), default: []].append(index)
        }
        let folded = foldNeighborhoods()

        self.countries = countries
        self.countryOfRegion = countryOfRegion
        countryOfName = Dictionary(
            countries.map { ($0.value.name, $0.key) }, uniquingKeysWith: { first, _ in first }
        )
        countryOfLabel = [:]
        for place in places where place.region == nil || place.region == (place.city ?? place.name) {
            let label = place.label
            if countryOfLabel[label] == nil { countryOfLabel[label] = place.country }
        }

        isLoaded = !places.isEmpty
        let took = (clock.now - started).components
        let seconds = Double(took.seconds) + Double(took.attoseconds) / 1e18
        logger.info("""
            geonames loaded: \(places.count) places, \(folded) named for their city, \
            \(grid.count) grid cells, in \(String(format: "%.2f", seconds)) s
            """)
        return isLoaded
    }

    /// One line of a tab-separated file, as byte ranges into it.
    private struct Row {
        let bytes: UnsafeBufferPointer<UInt8>
        let ranges: [Range<Int>]

        var count: Int { ranges.count }

        func isEmpty(_ index: Int) -> Bool { index >= ranges.count || ranges[index].isEmpty }

        func text(_ index: Int) -> String {
            guard index < ranges.count else { return "" }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[ranges[index]]), as: UTF8.self)
        }

        func integer(_ index: Int) -> Int {
            guard index < ranges.count else { return 0 }
            var value = 0
            for byte in bytes[ranges[index]] {
                guard byte >= 48, byte <= 57 else { return 0 }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
    }

    /// Every line of a tab-separated file, without first turning it, and each
    /// of its fields, into Strings.
    private static func eachRow(of data: Data, _ body: (Row) -> Void) {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(16)
            var start = 0
            for index in 0..<bytes.count {
                switch bytes[index] {
                case 9:  // tab
                    ranges.append(start..<index)
                    start = index + 1
                case 10:  // newline
                    ranges.append(start..<index)
                    start = index + 1
                    body(Row(bytes: bytes, ranges: ranges))
                    ranges.removeAll(keepingCapacity: true)
                default:
                    continue
                }
            }
            if start < bytes.count {
                ranges.append(start..<bytes.count)
                body(Row(bytes: bytes, ranges: ranges))
            }
        }
    }

    // MARK: - Neighborhoods

    /// Names each of a city's neighborhoods for the city. Three ways a place
    /// turns out to be part of a bigger one, each tight enough to leave a town
    /// that merely sits beside a city alone:
    ///
    /// 1. **Marked a section** (`PPLX`): Times Square, Hollywood, Rome's Celio.
    ///    It joins the biggest city that reaches it, in the same state or
    ///    province. A city reaches further the bigger it is (`reach`), so the
    ///    whole San Fernando Valley joins Los Angeles while Canyon Country
    ///    stays with Santa Clarita, which is where it is.
    /// 2. **The same municipality.** Paris's arrondissements are listed as
    ///    towns, but carry Paris's own municipal code. Only where the dataset
    ///    goes down to a municipality (admin4): in the US the deepest code is
    ///    a township, and Levittown is not Hempstead.
    /// 3. **Inside a capital's own division**, close in: London's boroughs, the
    ///    neighborhoods of Washington, Tokyo's wards.
    ///
    /// Returns how many were named for a city.
    private func foldNeighborhoods() -> Int {
        // Cities big enough to have neighborhoods of their own, on a grid of
        // their own, so the search for one doesn't wade through every village.
        var cities: [Int: [Int]] = [:]
        for (index, place) in places.enumerated()
        where place.population >= Self.cityPopulation && place.feature != "PPLX" {
            cities[Self.cell(place.latitude, place.longitude), default: []].append(index)
        }
        func nearby(_ place: Place, in grid: [Int: [Int]], _ visit: (Int) -> Void) {
            for deltaLat in -1...1 {
                for deltaLon in -1...1 {
                    guard let cell = grid[Self.cell(place.latitude + Double(deltaLat),
                                                    place.longitude + Double(deltaLon))]
                    else { continue }
                    for index in cell { visit(index) }
                }
            }
        }
        func kilometers(_ a: Place, _ b: Place) -> Double {
            HeaderPlaces.distance(a.latitude, a.longitude, b.latitude, b.longitude) / 1000
        }

        var parent: [Int: Int] = [:]

        // 1. Sections.
        for (index, place) in places.enumerated() where place.feature == "PPLX" {
            var best: Int?
            nearby(place, in: cities) { candidate in
                let city = places[candidate]
                guard city.population > place.population, city.depth >= 2,
                      city.county.hasPrefix(place.county) || place.county.hasPrefix(city.county),
                      kilometers(place, city) <= Self.reach(city.population)
                else { return }
                if best == nil || city.population > places[best!].population { best = candidate }
            }
            if let best { parent[index] = best }
        }

        // 2. The same municipality.
        var municipalities: [String: [Int]] = [:]
        for (index, place) in places.enumerated() where place.depth >= 5 {
            municipalities[place.divisions, default: []].append(index)
        }
        for members in municipalities.values where members.count > 1 {
            guard let main = members.max(by: { places[$0].population < places[$1].population })
            else { continue }
            for member in members where member != main && parent[member] == nil {
                let place = places[member]
                if places[main].population > 2 * place.population,
                   kilometers(place, places[main]) <= Self.capitalKilometers {
                    parent[member] = main
                }
            }
        }

        // 3. Inside a capital.
        for capitalIndex in places.indices
        where places[capitalIndex].feature == "PPLC" && places[capitalIndex].depth >= 2 {
            let capital = places[capitalIndex]
            nearby(capital, in: grid) { index in
                if index != capitalIndex, parent[index] == nil,
                   places[index].population < capital.population,
                   places[index].divisions.hasPrefix(capital.divisions),
                   kilometers(places[index], capital) <= Self.capitalKilometers {
                    parent[index] = capitalIndex
                }
            }
        }

        // A neighborhood of a neighborhood is part of the same city.
        var folded = 0
        for (index, first) in parent {
            var root = first
            var hops = 0
            while let next = parent[root], hops < 5 { root = next; hops += 1 }
            places[index].city = places[root].name
            folded += 1
        }
        return folded
    }

    /// Below this a place doesn't have neighborhoods: its reach (see `reach`)
    /// would be under a few kilometers anyway.
    private static let cityPopulation = 15_000

    /// How far a city's neighborhoods can be from its center: further the
    /// bigger it is. About 13 km for a city of 400,000, 40 km for Los Angeles,
    /// and never more than 60.
    private static func reach(_ population: Int) -> Double {
        min(0.02 * Double(population).squareRoot(), 60)
    }

    /// How far out a capital, or a municipality's main town, takes in places
    /// listed inside it: Greater London, but not the next city along.
    private static let capitalKilometers = 25.0

    // MARK: - Lookup

    /// Nearest known settlement, or nil when nothing is within ~150 km — mid
    /// ocean should read as nothing rather than as a town 400 km away.
    func nearest(latitude: Double, longitude: Double) -> Place? {
        guard isLoaded,
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0)
        else { return nil }

        var best: (index: Int, distance: Double)?

        // Widen the search ring until something is found. One degree of latitude
        // is ~111 km, so ring 1 covers any populated place in practice.
        for radius in 0...3 {
            for deltaLat in -radius...radius {
                for deltaLon in -radius...radius {
                    // Only the newly added ring, not cells already checked.
                    guard radius == 0 || abs(deltaLat) == radius || abs(deltaLon) == radius else {
                        continue
                    }
                    let key = Self.cell(latitude + Double(deltaLat), longitude + Double(deltaLon))
                    for index in grid[key] ?? [] {
                        let place = places[index]
                        let distance = Self.squaredDistance(
                            latitude, longitude, place.latitude, place.longitude
                        )
                        if best == nil || distance < best!.distance {
                            best = (index, distance)
                        }
                    }
                }
            }
            if best != nil, radius >= 1 { break }
        }

        guard let best else { return nil }
        // ~150 km in squared degrees, latitude-corrected below.
        guard best.distance < 1.8 else { return nil }
        return places[best.index]
    }

    func label(latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude)?.label
    }

    // MARK: - Countries

    /// The country a stored place name is in, by ISO code: from its region,
    /// or from the name itself for one with no region to say (`Tokyo`).
    func country(ofLabel label: String) -> String? {
        let parts = label.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return countryOfLabel[label] }
        let after = parts[1].trimmingCharacters(in: .whitespaces)
        if let country = countryOfRegion[after] { return country }
        if countries[after] != nil { return after }
        return countryOfName[after]
    }

    /// How a title names a country: "Italy", "the United Kingdom".
    func countryName(_ code: String) -> String? {
        countries[code].map { Self.spoken($0.name) }
    }

    /// The continent a country is on, by GeoNames' code: `EU`, `AS`.
    func continent(_ code: String) -> String? {
        countries[code]?.continent
    }

    /// A country's name as a sentence says it, with "the" where it takes one.
    private static func spoken(_ name: String) -> String {
        if name.hasPrefix("The ") { return "the " + name.dropFirst(4) }
        let takesThe = ["Islands", "Republic", "United", "Kingdom", "States", "Emirates"]
            .contains { name.contains($0) }
            || ["Bahamas", "Philippines", "Maldives", "Seychelles", "Comoros", "Gambia",
                "Isle of Man"].contains(name)
        return takesThe ? "the \(name)" : name
    }

    // MARK: - Geometry

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int {
        // Latitude spans 181 values after flooring; multiply by 512 to keep the
        // two axes from colliding.
        (Int(latitude.rounded(.down)) + 90) * 512 + (Int(longitude.rounded(.down)) + 180)
    }

    /// Squared degrees with longitude scaled by cos(latitude).
    ///
    /// Longitude degrees shrink toward the poles — 1° is 111 km at the equator
    /// and 55 km at 60°N. Ignoring that makes high-latitude lookups pick the
    /// wrong town.
    private static func squaredDistance(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double
    ) -> Double {
        let deltaLat = lat1 - lat2
        var deltaLon = lon1 - lon2
        // Shortest way around the antimeridian.
        if deltaLon > 180 { deltaLon -= 360 }
        if deltaLon < -180 { deltaLon += 360 }
        let scale = cos(lat1 * .pi / 180)
        let scaledLon = deltaLon * scale
        return deltaLat * deltaLat + scaledLon * scaledLon
    }
}

// MARK: - Application storage

private struct GeocoderKey: StorageKey {
    typealias Value = Geocoder
}

import Vapor

extension Application {
    var geocoder: Geocoder? {
        get { storage[GeocoderKey.self] }
        set { storage[GeocoderKey.self] = newValue }
    }
}
