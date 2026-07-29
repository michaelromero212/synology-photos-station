import Foundation
import SQLKit
import Vapor

/// `FrameStationServer geocode` — fills `place_name` for assets that already
/// have coordinates.
///
/// Needed because geocoding arrived after the ingest pipeline: anything imported
/// or uploaded before it has latitude and longitude but no place. Also the way
/// to re-run after updating the GeoNames dataset.
struct GeocodeCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "force", help: "Recompute even where place_name is already set")
        var force: Bool

        @Option(name: "batch", short: "b", help: "Rows per update batch (default 500)")
        var batch: Int?
    }

    var help: String { "Fill in place names for assets that have coordinates." }

    private struct Row: Decodable {
        let id: UUID
        let lat: Double
        let lon: Double
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard let geocoder = app.geocoder, geocoder.isLoaded else {
            throw Abort(.internalServerError, reason: """
                No GeoNames dataset loaded. Run Scripts/fetch-geonames.sh and set \
                FRAMESTATION_GEONAMES_DIR, or use the container image which bundles it.
                """)
        }

        let batchSize = max(1, signature.batch ?? 500)
        let filter = signature.force ? "" : "AND place_name IS NULL"

        let rows = try await app.sql.raw("""
            SELECT id, lat, lon FROM assets
            WHERE lat IS NOT NULL AND lon IS NOT NULL \(unsafeRaw: filter)
            """).all(decoding: Row.self)

        guard !rows.isEmpty else {
            console.info("Nothing to geocode.")
            return
        }
        console.info("Geocoding \(rows.count) assets…")

        var named = 0, unmatched = 0
        for chunk in stride(from: 0, to: rows.count, by: batchSize).map({
            Array(rows[$0..<min($0 + batchSize, rows.count)])
        }) {
            // Resolve labels before the transaction so the closure captures only
            // immutable data — mutating counters across a Sendable boundary is
            // an error under Swift 6.
            let resolved: [(UUID, String)] = chunk.compactMap { row in
                geocoder.label(latitude: row.lat, longitude: row.lon).map { (row.id, $0) }
            }
            unmatched += chunk.count - resolved.count

            // One transaction per batch: 100k single-row updates would be
            // 100k round trips.
            try await app.withPinnedConnection { sql in
                try await sql.raw("BEGIN").run()
                do {
                    for (id, label) in resolved {
                        try await sql.raw("""
                            UPDATE assets SET place_name = \(bind: label) WHERE id = \(bind: id)
                            """).run()
                    }
                    try await sql.raw("COMMIT").run()
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
            named += resolved.count
            console.info("  \(named + unmatched)/\(rows.count)")
        }

        console.info("")
        console.info("  Named:     \(named)")
        console.info("  No match:  \(unmatched)")
        if unmatched > 0 {
            console.info("  (no settlement within ~150 km — mid-ocean or remote coordinates)")
        }
    }
}
