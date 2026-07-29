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
/// Data: GeoNames cities1000, CC BY 4.0. Built by `Scripts/fetch-geonames.sh`.
final class Geocoder: @unchecked Sendable {
    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String
        /// Region name already resolved, e.g. `Virginia` rather than `VA`.
        let region: String?

        /// `Culpeper, Virginia` — or `Culpeper, US` where no region is known.
        var label: String {
            if let region, !region.isEmpty { return "\(name), \(region)" }
            return country.isEmpty ? name : "\(name), \(country)"
        }
    }

    private var places: [Place] = []
    /// Whole-degree cell → indices into `places`. Turns a 170k-row scan into a
    /// few dozen distance checks.
    private var grid: [Int: [Int]] = [:]

    private(set) var isLoaded = false
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Loading

    /// Returns false when the dataset isn't present. That is not an error —
    /// geocoding is optional and `place_name` simply stays null, which the
    /// clients already handle by falling back to raw coordinates.
    @discardableResult
    func load(directory: String) -> Bool {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let citiesURL = root.appendingPathComponent("cities.tsv")
        let adminURL = root.appendingPathComponent("admin1.tsv")

        guard let citiesText = try? String(contentsOf: citiesURL, encoding: .utf8) else {
            logger.info("no geonames dataset at \(directory) — place names disabled")
            return false
        }

        // "US.VA" -> "Virginia"
        var regions: [String: String] = [:]
        if let adminText = try? String(contentsOf: adminURL, encoding: .utf8) {
            for line in adminText.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count >= 2 { regions[String(parts[0])] = String(parts[1]) }
            }
        }

        var loaded: [Place] = []
        loaded.reserveCapacity(180_000)

        for line in citiesText.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 5,
                  let latitude = Double(parts[1]),
                  let longitude = Double(parts[2])
            else { continue }

            let country = String(parts[3])
            let adminCode = String(parts[4])
            loaded.append(
                Place(
                    name: String(parts[0]),
                    latitude: latitude,
                    longitude: longitude,
                    country: country,
                    region: regions["\(country).\(adminCode)"]
                )
            )
        }

        places = loaded
        grid = [:]
        for (index, place) in loaded.enumerated() {
            grid[Self.cell(place.latitude, place.longitude), default: []].append(index)
        }

        isLoaded = !places.isEmpty
        logger.info("geonames loaded: \(places.count) places, \(grid.count) grid cells")
        return isLoaded
    }

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
