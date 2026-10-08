import Foundation
import SQLKit

/// The places people call by their own names rather than by the nearest town.
///
/// The town dataset (`Geocoder`) names the nearest town big enough to be in
/// it, and for the places a family remembers best that is the wrong answer.
/// Walt Disney World's parks sit nearest three different suburbs (Horizon
/// West, Celebration and Citrus Ridge), so four days there came out as "Four
/// days in Florida". Duck is too small to be in the dataset, so a week there
/// was "Seven days in Southern Shores", and the rest of the Outer Banks is
/// named after towns up to forty kilometers away. Old Faithful is "West
/// Yellowstone, Montana", and Glacier's Many Glacier is a town in Alberta.
///
/// So this is a short, hand-made list of those places, each drawn as a few
/// circles over the ground it covers. Two kinds, because two different things
/// go wrong:
///
/// - A **destination** is somewhere the towns can't name: a resort, a park, a
///   stretch of coast with no town big enough to be in the dataset. A photo
///   taken inside one is filed under its name in `assets.destination`, beside
///   its town in `place_name`, which stays put so the town can still be
///   searched. Everything that shows a place reads `COALESCE(destination,
///   place_name)`: day headers, trips, Places, search, the Information panel.
///   The names match everywhere.
/// - An **area** is a cluster of real towns that a trip moving between them is
///   called by: Orlando, Cape Cod, the Smokies. Its photos keep their towns,
///   so a day in Kissimmee still says Kissimmee, and only a trip's title uses
///   it: "Five days in Orlando" for a week split between Disney World,
///   Universal and a rental in Kissimmee. Searching for one finds the photos
///   inside it.
///
/// Change the list and bump `version`, and every photo with coordinates is
/// filed again on the next boot. See `PlaceFiling`.
enum Destinations {
    /// Bump with any change to the lists below.
    static let version = 1

    /// A destination or an area: which list it is in says which.
    struct Place: Sendable {
        /// "Walt Disney World", "Outer Banks".
        let name: String
        /// What follows the name in a stored label, the way the town dataset
        /// writes one: "Walt Disney World, Florida".
        let region: String
        /// How a title says being there: "at" Walt Disney World, "in" the
        /// Outer Banks, "on" Cape Cod.
        let preposition: String
        /// Whether its name takes "the": the Outer Banks, the Grand Canyon.
        let takesThe: Bool
        let circles: [Circle]
        /// Trip kinds that would only say again what its name already says. A
        /// theme park trip to Walt Disney World is a trip to Walt Disney World.
        /// See `CurationVocabulary.events`.
        let implies: Set<String>
        /// More words that find it in search: "obx". A destination is also
        /// found by any word of its name, which is in its label. An area has
        /// no label, so these are the only words that find it.
        let aliases: Set<String>

        /// The label a destination's photos are filed under.
        var label: String { "\(name), \(region)" }
        /// "the Outer Banks".
        var spoken: String { takesThe ? "the \(name)" : name }
        /// "in the Outer Banks".
        var locative: String { "\(preposition) \(spoken)" }

        func contains(latitude: Double, longitude: Double) -> Bool {
            circles.contains { $0.contains(latitude: latitude, longitude: longitude) }
        }
    }

    struct Circle: Sendable {
        let latitude: Double
        let longitude: Double
        let meters: Double

        init(_ latitude: Double, _ longitude: Double, km: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.meters = km * 1000
        }

        func contains(latitude: Double, longitude: Double) -> Bool {
            // A box first: almost every photo is nowhere near, and this saves
            // the trigonometry for the few that are.
            let latitudeSpan = meters / 111_000
            guard abs(latitude - self.latitude) <= latitudeSpan else { return false }
            let longitudeSpan = latitudeSpan / max(cos(self.latitude * .pi / 180), 0.01)
            guard abs(longitude - self.longitude) <= longitudeSpan else { return false }
            return HeaderPlaces.distance(self.latitude, self.longitude, latitude, longitude) <= meters
        }
    }

    // MARK: - Finding one

    /// The destination a photo taken here is filed under, or nil.
    ///
    /// Where two overlap, the one drawn tighter wins, as the more particular
    /// answer: Dollywood, not the Smokies around it.
    static func destination(latitude: Double, longitude: Double) -> Place? {
        var best: (place: Place, meters: Double)?
        for place in destinations {
            for circle in place.circles
            where circle.contains(latitude: latitude, longitude: longitude) {
                if best == nil || circle.meters < best!.meters { best = (place, circle.meters) }
            }
        }
        return best?.place
    }

    /// What `assets.destination` holds for a photo taken here.
    static func label(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return destination(latitude: latitude, longitude: longitude)?.label
    }

    /// The destination a stored label names. A town the dataset happens to
    /// call the same, such as "Grand Canyon, Arizona", counts: it is the same
    /// place, and it reads "at the Grand Canyon" either way.
    static func named(label: String) -> Place? { byLabel[label] }

    /// The areas a point is inside.
    static func areas(containing latitude: Double, _ longitude: Double) -> [Place] {
        areas.filter { $0.contains(latitude: latitude, longitude: longitude) }
    }

    /// The destination or area a title calls this: "the Outer Banks".
    static func place(spoken: String) -> Place? { bySpoken[spoken] }

    /// The destinations and areas a searched word can mean beyond its
    /// letters: the labels "obx" files photos under, and the areas "orlando"
    /// covers.
    static func meanings(of word: String) -> (labels: [String], areas: [Place]) {
        let word = word.lowercased()
        return (
            destinations.filter { $0.aliases.contains(word) }.map(\.label),
            areas.filter { $0.aliases.contains(word) }
        )
    }

    /// Photos inside any of these circles, for search. A box first, so the
    /// index-free scan only does the trigonometry on photos that are near.
    static func inside(_ circles: [Circle]) -> SQLQueryString {
        var clauses: [SQLQueryString] = []
        for circle in circles {
            let latitudeSpan = circle.meters / 111_000
            let longitudeSpan = latitudeSpan / max(cos(circle.latitude * .pi / 180), 0.01)
            clauses.append("""
                (a.lat BETWEEN \(bind: circle.latitude - latitudeSpan) AND \(bind: circle.latitude + latitudeSpan)
                 AND a.lon BETWEEN \(bind: circle.longitude - longitudeSpan) AND \(bind: circle.longitude + longitudeSpan)
                 AND 6371000 * acos(LEAST(1, GREATEST(-1,
                       sin(radians(a.lat)) * sin(radians(\(bind: circle.latitude)))
                     + cos(radians(a.lat)) * cos(radians(\(bind: circle.latitude)))
                     * cos(radians(a.lon - \(bind: circle.longitude)))
                     ))) <= \(bind: circle.meters))
                """)
        }
        guard var joined = clauses.first else { return "false" }
        for clause in clauses.dropFirst() { joined = "\(joined) OR \(clause)" }
        return "(\(joined))"
    }

    private static let byLabel: [String: Place] = Dictionary(
        destinations.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first }
    )
    private static let bySpoken: [String: Place] = Dictionary(
        (destinations + areas).map { ($0.spoken, $0) }, uniquingKeysWith: { first, _ in first }
    )

    // MARK: - The list

    private static let themePark: Set<String> = ["amusement_park"]
    private static let skiing: Set<String> = ["snow"]

    private static func destination(
        _ name: String, _ region: String, _ preposition: String, the: Bool = false,
        implies: Set<String> = [], aliases: Set<String> = [], _ circles: [Circle]
    ) -> Place {
        Place(
            name: name, region: region, preposition: preposition,
            takesThe: the, circles: circles, implies: implies, aliases: aliases
        )
    }

    private static func area(
        _ name: String, _ region: String, _ preposition: String, the: Bool = false,
        aliases: Set<String>, _ circles: [Circle]
    ) -> Place {
        Place(
            name: name, region: region, preposition: preposition,
            takesThe: the, circles: circles, implies: [], aliases: aliases
        )
    }

    static let destinations: [Place] = [
        // Theme parks. Their photos land in whatever suburb is nearest, and
        // nobody calls a day at Epcot a day in Celebration.
        destination("Walt Disney World", "Florida", "at", implies: themePark, aliases: ["wdw"], [
            // Magic Kingdom and the resorts on its lakes.
            Circle(28.411, -81.580, km: 2.6),
            // Epcot and Hollywood Studios, and the resorts between them.
            Circle(28.368, -81.552, km: 2.6),
            // Animal Kingdom, Blizzard Beach, the All-Stars and Coronado Springs.
            Circle(28.354, -81.585, km: 2.8),
            // Disney Springs, Typhoon Lagoon and the resorts along the river.
            Circle(28.374, -81.525, km: 2.3),
            // Pop Century, Art of Animation and ESPN Wide World of Sports.
            Circle(28.346, -81.550, km: 1.7),
        ]),
        destination("Universal Orlando", "Florida", "at", implies: themePark, [
            // Both parks, CityWalk, Volcano Bay and the hotels.
            Circle(28.4725, -81.4685, km: 1.6),
            // Epic Universe.
            Circle(28.4410, -81.4470, km: 1.5),
        ]),
        destination("SeaWorld Orlando", "Florida", "at", implies: themePark, [
            // With Aquatica and Discovery Cove.
            Circle(28.4105, -81.4595, km: 1.3),
        ]),
        destination("Kennedy Space Center", "Florida", "at", [
            Circle(28.5244, -80.6820, km: 1.5),
            // The Saturn V hall the bus tour stops at.
            Circle(28.6011, -80.6614, km: 0.8),
        ]),
        destination("Legoland", "Florida", "at", implies: themePark, [
            Circle(27.9887, -81.6902, km: 1.0),
        ]),
        destination("Busch Gardens", "Florida", "at", implies: themePark, [
            Circle(28.0372, -82.4195, km: 1.1),
        ]),
        destination("Disneyland", "California", "at", implies: themePark, [
            // Both parks, Downtown Disney and the hotels.
            Circle(33.8100, -117.9200, km: 1.0),
        ]),
        destination("Universal Studios Hollywood", "California", "at", implies: themePark, [
            Circle(34.1381, -118.3534, km: 0.9),
        ]),
        destination("Busch Gardens", "Virginia", "at", implies: themePark, [
            Circle(37.2343, -76.6452, km: 1.0),
        ]),
        destination("Kings Dominion", "Virginia", "at", implies: themePark, [
            Circle(37.8393, -77.4448, km: 1.0),
        ]),
        destination("Dollywood", "Tennessee", "at", implies: themePark, [
            Circle(35.7952, -83.5307, km: 0.9),
        ]),
        destination("Cedar Point", "Ohio", "at", implies: themePark, [
            Circle(41.4822, -82.6835, km: 1.3),
        ]),

        // The Strip is in Paradise, Nevada, as far as the dataset knows.
        destination("Las Vegas", "Nevada", "in", [
            // Mandalay Bay to New York-New York and the MGM Grand.
            Circle(36.0985, -115.1735, km: 1.3),
            // Park MGM to the Linq: Bellagio, Caesars, Paris, the Cosmopolitan.
            Circle(36.1160, -115.1720, km: 1.3),
            // The Venetian, Wynn, Resorts World and the Fashion Show.
            Circle(36.1310, -115.1665, km: 1.3),
            // The Sahara and the Strat.
            Circle(36.1455, -115.1570, km: 1.0),
        ]),

        // Barrier islands whose towns are mostly too small for the dataset.
        // Corolla came out as Currituck, on the mainland, and Ocracoke as
        // Buxton, forty kilometers up the coast.
        destination("Outer Banks", "North Carolina", "in", the: true, aliases: ["obx"], [
            Circle(36.500, -75.855, km: 5.5),   // Carova
            Circle(36.400, -75.835, km: 6.0),   // Corolla
            Circle(36.300, -75.800, km: 6.5),   // Pine Island and Sanderling
            Circle(36.190, -75.762, km: 6.0),   // Duck
            Circle(36.095, -75.722, km: 6.0),   // Southern Shores and Kitty Hawk
            Circle(36.010, -75.670, km: 6.0),   // Kill Devil Hills and Colington
            Circle(35.930, -75.615, km: 6.0),   // Nags Head
            Circle(35.875, -75.665, km: 5.5),   // Roanoke Island: Manteo and Wanchese
            Circle(35.830, -75.565, km: 6.0),   // Bodie Island
            Circle(35.740, -75.515, km: 6.0),   // Oregon Inlet
            Circle(35.650, -75.480, km: 6.0),   // Pea Island
            Circle(35.565, -75.468, km: 6.0),   // Rodanthe, Waves and Salvo
            Circle(35.460, -75.485, km: 6.5),
            Circle(35.355, -75.505, km: 6.0),   // Avon
            Circle(35.260, -75.550, km: 5.5),   // Buxton and the Hatteras lighthouse
            Circle(35.225, -75.655, km: 5.5),   // Frisco and Hatteras
            Circle(35.180, -75.790, km: 5.0),   // Ocracoke Island
            Circle(35.155, -75.850, km: 5.0),
            Circle(35.120, -75.930, km: 5.0),
            Circle(35.100, -76.000, km: 4.5),   // Ocracoke village
        ]),

        // National parks, whose nearest town is often outside them, sometimes
        // in another state.
        destination("Yellowstone", "Wyoming", "in", [
            Circle(44.470, -110.800, km: 15),   // Old Faithful, Grand Prismatic and the geyser basins
            Circle(44.650, -110.750, km: 13),   // Madison and Norris
            Circle(44.720, -110.480, km: 12),   // Canyon and Hayden Valley
            Circle(44.480, -110.420, km: 15),   // Yellowstone Lake, West Thumb and Fishing Bridge
            Circle(44.940, -110.660, km: 8),    // Mammoth Hot Springs
            Circle(44.880, -110.250, km: 14),   // Tower and Lamar Valley
        ]),
        destination("Grand Teton National Park", "Wyoming", "in", [
            Circle(43.730, -110.700, km: 11),   // Jenny Lake, Moose and Mormon Row
            Circle(43.870, -110.600, km: 11),   // Signal Mountain, Jackson Lake Lodge and Colter Bay
        ]),
        destination("Grand Canyon", "Arizona", "at", the: true, [
            Circle(36.055, -112.140, km: 12),   // The South Rim, the village and Tusayan
            Circle(36.044, -111.826, km: 5),    // Desert View
            Circle(36.198, -112.052, km: 6),    // The North Rim
        ]),
        destination("Zion", "Utah", "in", [
            Circle(37.230, -112.970, km: 7.5),  // Zion Canyon and Springdale
            Circle(37.226, -112.880, km: 5),    // The east side
            Circle(37.453, -113.225, km: 5),    // Kolob Canyons
        ]),
        destination("Bryce Canyon", "Utah", "at", [
            Circle(37.620, -112.170, km: 9),    // The amphitheater, the lodge and Bryce Canyon City
            Circle(37.530, -112.220, km: 7),    // The viewpoints south to Rainbow Point
        ]),
        destination("Arches", "Utah", "in", [
            Circle(38.750, -109.560, km: 7),    // Delicate Arch, the Fiery Furnace and Devils Garden
            Circle(38.660, -109.580, km: 6),    // The visitor center, Balanced Rock and the Windows
        ]),
        destination("Yosemite", "California", "in", [
            Circle(37.740, -119.590, km: 8),    // The valley and Glacier Point
            Circle(37.870, -119.360, km: 8),    // Tuolumne Meadows
            Circle(37.530, -119.630, km: 6),    // Wawona and the Mariposa Grove
        ]),
        destination("Joshua Tree", "California", "in", [
            Circle(34.000, -116.150, km: 12),   // Hidden Valley, Keys View and Jumbo Rocks
            Circle(33.920, -115.930, km: 6),    // The Cholla Cactus Garden
        ]),
        destination("Glacier National Park", "Montana", "in", [
            Circle(48.560, -113.940, km: 8),    // Apgar and West Glacier
            Circle(48.650, -113.800, km: 9),    // Lake McDonald Lodge and Logan Pass
            Circle(48.760, -113.600, km: 9),    // Many Glacier
            Circle(48.730, -113.450, km: 6),    // St. Mary and Rising Sun
            Circle(48.490, -113.370, km: 6),    // Two Medicine
        ]),
        destination("Rocky Mountain National Park", "Colorado", "in", [
            Circle(40.330, -105.640, km: 6),    // Bear Lake and Moraine Park
            Circle(40.420, -105.730, km: 9),    // Trail Ridge Road
            Circle(40.330, -105.840, km: 5),    // The Kawuneeche Valley
        ]),
        destination("Acadia", "Maine", "in", [
            // Cadillac Mountain, Jordan Pond and the loop road, short of Bar
            // Harbor, which is a town people name.
            Circle(44.335, -68.220, km: 5),
            Circle(44.338, -68.059, km: 4),     // The Schoodic Peninsula
        ]),
        destination("Great Smoky Mountains", "Tennessee", "in", the: true, aliases: ["smokies", "smoky"], [
            // Short of Gatlinburg and Townsend, which are towns people name.
            Circle(35.600, -83.480, km: 9),     // Newfound Gap, Clingmans Dome and the Chimney Tops
            Circle(35.655, -83.580, km: 5),     // Elkmont and Laurel Falls
            Circle(35.590, -83.820, km: 6),     // Cades Cove
        ]),
        destination("Shenandoah National Park", "Virginia", "in", [
            // Skyline Drive, north to south, short of the towns at either end.
            Circle(38.860, -78.210, km: 6),
            Circle(38.790, -78.260, km: 6),
            Circle(38.720, -78.300, km: 6),
            Circle(38.650, -78.330, km: 6),     // Thornton Gap
            Circle(38.585, -78.380, km: 6),     // Skyland
            Circle(38.555, -78.310, km: 3),     // Old Rag
            Circle(38.520, -78.430, km: 6),     // Big Meadows
            Circle(38.450, -78.470, km: 6),
            Circle(38.380, -78.530, km: 6),     // Swift Run Gap
            Circle(38.310, -78.600, km: 6),
            Circle(38.240, -78.670, km: 6),     // Loft Mountain
            Circle(38.170, -78.730, km: 6),
            Circle(38.100, -78.790, km: 5),
        ]),
        destination("Everglades", "Florida", "in", the: true, [
            Circle(25.7575, -80.7663, km: 6),   // Shark Valley
            Circle(25.762, -80.630, km: 6),     // The airboats along the Tamiami Trail
            Circle(25.390, -80.600, km: 5),     // The main entrance and the Anhinga Trail
            Circle(25.400, -80.700, km: 6),
            Circle(25.300, -80.800, km: 6),
            Circle(25.200, -80.870, km: 6),
            Circle(25.1414, -80.9244, km: 6),   // Flamingo
        ]),
        destination("Mount Rainier", "Washington", "at", [
            Circle(46.7865, -121.7353, km: 6),  // Paradise
            Circle(46.9140, -121.6440, km: 5),  // Sunrise
            Circle(46.7500, -121.8130, km: 4),  // Longmire
        ]),

        // Ski resorts, named after towns twenty kilometers off.
        destination("Snowshoe", "West Virginia", "at", implies: skiing, [
            Circle(38.4108, -79.9941, km: 3),
        ]),
        destination("Wintergreen", "Virginia", "at", implies: skiing, [
            Circle(37.9270, -78.9440, km: 3),
        ]),
    ]

    static let areas: [Place] = [
        // Disney World, Universal and SeaWorld, and the towns people stay in
        // between them.
        area("Orlando", "Florida", "in", aliases: ["orlando"], [
            Circle(28.420, -81.470, km: 25),
        ]),
        area("Smokies", "Tennessee", "in", the: true, aliases: ["smokies", "smoky"], [
            Circle(35.750, -83.550, km: 16),    // Gatlinburg, Pigeon Forge and Sevierville
            Circle(35.620, -83.750, km: 12),    // Townsend and Cades Cove
            Circle(35.600, -83.480, km: 12),    // The national park
            Circle(35.480, -83.380, km: 12),    // Cherokee and Bryson City
        ]),
        area("Florida Keys", "Florida", "in", the: true, aliases: ["keys"], [
            Circle(25.150, -80.400, km: 10),    // Key Largo
            Circle(24.980, -80.560, km: 10),    // Tavernier and Islamorada
            Circle(24.820, -80.800, km: 10),
            Circle(24.710, -81.080, km: 10),    // Marathon
            Circle(24.660, -81.350, km: 10),    // Big Pine Key
            Circle(24.620, -81.580, km: 10),
            Circle(24.560, -81.770, km: 10),    // Key West
        ]),
        area("Cape Cod", "Massachusetts", "on", aliases: ["cape", "cod"], [
            Circle(41.580, -70.580, km: 10),    // Falmouth and Woods Hole
            Circle(41.740, -70.590, km: 6),     // Bourne
            Circle(41.700, -70.430, km: 10),    // Sandwich and Mashpee
            Circle(41.670, -70.230, km: 12),    // Hyannis, Yarmouth and Dennis
            Circle(41.740, -69.990, km: 12),    // Chatham, Harwich, Brewster and Orleans
            Circle(41.990, -70.080, km: 12),    // Wellfleet, Truro and Provincetown
        ]),
        area("Martha's Vineyard", "Massachusetts", "on", aliases: ["martha's", "marthas", "vineyard"], [
            Circle(41.400, -70.580, km: 10),    // Edgartown, Oak Bluffs and Vineyard Haven
            Circle(41.360, -70.730, km: 9),     // West Tisbury, Chilmark and Aquinnah
        ]),
        area("Hamptons", "New York", "in", the: true, aliases: ["hamptons"], [
            Circle(40.830, -72.560, km: 8),     // Westhampton and Hampton Bays
            Circle(40.920, -72.330, km: 13),    // Southampton, Bridgehampton and Sag Harbor
            Circle(41.000, -72.120, km: 12),    // East Hampton and Amagansett
            Circle(41.040, -71.950, km: 6),     // Montauk
        ]),
        area("Lake Tahoe", "California", "at", aliases: ["lake", "tahoe"], [
            Circle(39.090, -120.040, km: 22),
        ]),
        area("Napa Valley", "California", "in", aliases: ["napa", "valley"], [
            Circle(38.360, -122.330, km: 10),   // Napa and Yountville
            Circle(38.540, -122.510, km: 10),   // St. Helena and Calistoga
        ]),
        area("Myrtle Beach", "South Carolina", "in", aliases: ["myrtle", "beach"], [
            Circle(33.850, -78.650, km: 8),     // North Myrtle Beach
            Circle(33.740, -78.830, km: 10),    // Myrtle Beach
            Circle(33.580, -79.000, km: 9),     // Surfside Beach, Garden City and Murrells Inlet
        ]),
        area("Acadia", "Maine", "in", aliases: ["acadia"], [
            // Mount Desert Island, Bar Harbor and all.
            Circle(44.340, -68.280, km: 15),
        ]),
        area("Moab", "Utah", "in", aliases: ["moab"], [
            // Arches, Canyonlands' Island in the Sky and the town between them.
            Circle(38.620, -109.620, km: 30),
        ]),
        area("Jackson Hole", "Wyoming", "in", aliases: ["jackson", "hole"], [
            Circle(43.600, -110.750, km: 22),   // Jackson, Teton Village and the south of the park
            Circle(43.860, -110.600, km: 12),   // Jackson Lake
        ]),
        // Hawaii's islands, which a week is spent on more than in any town.
        area("Maui", "Hawaii", "on", aliases: ["maui"], [
            Circle(20.920, -156.660, km: 15),   // Lahaina, Kaanapali and Kapalua
            Circle(20.790, -156.450, km: 18),   // Kahului, Kihei and Wailea
            Circle(20.750, -156.250, km: 15),   // Upcountry and Haleakala
            Circle(20.750, -156.050, km: 12),   // Hana
        ]),
        area("Oahu", "Hawaii", "on", aliases: ["oahu"], [
            Circle(21.470, -157.980, km: 32),
            Circle(21.330, -157.750, km: 12),   // Waikiki to Makapuu
        ]),
        area("Kauai", "Hawaii", "on", aliases: ["kauai"], [
            Circle(22.070, -159.530, km: 32),
        ]),
        area("Big Island", "Hawaii", "on", the: true, aliases: ["big", "island"], [
            Circle(19.640, -155.990, km: 30),   // Kona
            Circle(19.720, -155.080, km: 30),   // Hilo
            Circle(19.420, -155.290, km: 25),   // Volcano and Kilauea
            Circle(20.020, -155.670, km: 25),   // Waimea and Kohala
            Circle(19.100, -155.650, km: 25),   // The south
        ]),
    ]
}
