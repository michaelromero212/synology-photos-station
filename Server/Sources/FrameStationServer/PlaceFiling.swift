import Foundation
import SQLKit
import Vapor

/// Names every stored photo's place again when the rules for naming one
/// change: how towns are named (`Geocoder.version`), or the list of places
/// that go by names of their own (`Destinations.version`).
///
/// A photo is named when it arrives and when its location is edited. This is
/// for the library already stored when a rule changes, so that a week in
/// Paris taken years ago reads "Paris" like one taken today. Without the town
/// dataset, towns are left as they are, and so is their version, for a boot
/// that has it.
enum PlaceFiling {
    static func refile(on app: Application) async {
        struct Row: Decodable {
            let id: UUID
            let lat: Double
            let lon: Double
        }
        let sql = app.sql
        let geocoder = app.geocoder.flatMap { $0.isLoaded ? $0 : nil }
        let towns = geocoder != nil
        var cursor = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var filed = 0
        do {
            while true {
                // Along the primary key, in batches, off the boot path.
                let rows = try await sql.raw("""
                    SELECT id, lat, lon FROM assets
                    WHERE id > \(bind: cursor)
                      AND lat IS NOT NULL AND lon IS NOT NULL
                      AND (destination_version < \(bind: Destinations.version)
                           OR (\(bind: towns) AND place_version < \(bind: Geocoder.version)))
                    ORDER BY id
                    LIMIT 1000
                    """).all(decoding: Row.self)
                guard let last = rows.last else { break }
                cursor = last.id

                // Empty for none: an array bind can't carry a NULL element.
                let destinations = rows.map {
                    Destinations.label(latitude: $0.lat, longitude: $0.lon) ?? ""
                }
                let places = rows.map {
                    geocoder?.label(latitude: $0.lat, longitude: $0.lon) ?? ""
                }
                // A row whose coordinates changed between the read and this
                // write is left alone: the edit that changed them named it.
                // A town the dataset can't find is kept rather than erased.
                try await sql.raw("""
                    UPDATE assets AS a
                    SET destination = NULLIF(v.destination, ''),
                        destination_version = \(bind: Destinations.version),
                        place_name = CASE WHEN \(bind: towns)
                            THEN COALESCE(NULLIF(v.place, ''), a.place_name)
                            ELSE a.place_name END,
                        place_version = CASE WHEN \(bind: towns)
                            THEN \(bind: Geocoder.version)
                            ELSE a.place_version END
                    FROM unnest(\(bind: rows.map(\.id))::uuid[], \(bind: rows.map(\.lat))::float8[],
                                \(bind: rows.map(\.lon))::float8[], \(bind: destinations)::text[],
                                \(bind: places)::text[])
                         AS v(id, lat, lon, destination, place)
                    WHERE a.id = v.id AND a.lat = v.lat AND a.lon = v.lon
                    """).run()
                filed += rows.count
                // A breath between batches, so a library being named again
                // never holds up the app's own requests.
                try await Task.sleep(for: .milliseconds(100))
            }
            if filed > 0 {
                app.logger.info("places: named \(filed) photos again")
            }
        } catch {
            app.logger.error("places: naming stopped: \(error)")
        }
    }
}
