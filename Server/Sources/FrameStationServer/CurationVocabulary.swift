import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// Which of Vision's labels count as evidence for what, and what an occasion
/// built from that evidence is called.
///
/// Devices send what Vision saw, in Vision's own words ("birthday_cake",
/// "christmas_tree") with a confidence for each, and nothing about what any of
/// it means. Meaning is decided here, in one place, for two reasons:
/// - tuning it after feedback is a server update rather than an app update;
/// - a photo analyzed once never has to be analyzed again because a rule
///   changed.
///
/// `version` goes up whenever a rule does. Each stored photo records the
/// version its tags were derived under, and `retag` re-derives the stale ones
/// when the server boots.
///
/// Every threshold here is a starting point, to be tuned against how it does
/// on the family's own photographs. The label names are Vision's revision 2
/// taxonomy (1,303 identifiers).
enum CurationVocabulary {
    /// 2: search terms (`terms`) are derived and stored beside the tags.
    /// 3: and the single words inside them (`words`).
    /// 4: a gown and a ceremony no longer make a wedding, since a graduation
    ///    has both, and nor does anything short of a wedding's own labels in a
    ///    photo Vision also called a graduation.
    /// 5: an outing is what Vision saw it was: bowling, skating, go-karts,
    ///    climbing, fishing. A family's bowling night was "Game day in West
    ///    Gate" (his library, 2026-11-10), because bowling is a sport and has
    ///    balls; "Game day" is now only for a game.
    /// 6: a lake day is a lake day. Vision calls life jackets "sport" and
    ///    "sports equipment", and Memorial Day on a pontoon boat was "Game
    ///    day" (his library, 2026-11-11). "Sport" alone no longer makes a
    ///    game, nothing on or by the water is one, lakes have their own days
    ///    and stays, and "On the water" is "Boating".
    static let version = 6

    // MARK: - Labels to tags

    /// One tag, and what earns it.
    struct Rule: Sendable {
        let tag: String
        /// Any one of these, at or above its confidence, is enough.
        let strong: [String: Float]
        /// Otherwise two of these together are.
        let supporting: [String: Float]
        /// Unless the photo shows one of these, which explains the supporting
        /// labels better: a cap and gown in a graduation photo is not a
        /// wedding's gown.
        let unless: [String: Float]

        init(
            _ tag: String, strong: [String: Float], supporting: [String: Float] = [:],
            unless: [String: Float] = [:]
        ) {
            self.tag = tag
            self.strong = strong
            self.supporting = supporting
            self.unless = unless
        }
    }

    static let rules: [Rule] = [
        // Occasions.
        Rule("birthday",
             strong: ["birthday_cake": 0.3],
             supporting: ["candle": 0.3, "balloon": 0.3, "cake": 0.4, "cupcake": 0.4,
                          "gift": 0.4, "celebration": 0.3]),
        // Not "gown" or "ceremony": a graduation is both, and a cap-and-gown
        // afternoon came out as "Wedding in Linton Hall".
        Rule("wedding",
             strong: ["wedding": 0.3, "wedding_dress": 0.3, "bride": 0.3, "wedding_cake": 0.3],
             supporting: ["groom": 0.3, "bridesmaid": 0.3, "bouquet": 0.3, "tuxedo": 0.3],
             unless: ["graduation": 0.3]),
        Rule("graduation", strong: ["graduation": 0.3]),
        Rule("concert",
             strong: ["concert": 0.3, "performance": 0.4],
             supporting: ["crowd": 0.3, "musical_instrument": 0.3, "guitar": 0.3,
                          "microphone": 0.3, "drum": 0.3, "music": 0.3, "piano": 0.3,
                          "violin": 0.3, "theater": 0.3, "speakers_music": 0.3]),

        // Sports, one tag each so a card can say which, and a general one for
        // when it can't.
        Rule("soccer", strong: ["soccer": 0.3]),
        Rule("baseball", strong: ["baseball": 0.3, "baseball_bat": 0.3]),
        Rule("softball", strong: ["softball": 0.3]),
        Rule("basketball", strong: ["basketball": 0.3]),
        Rule("football", strong: ["football": 0.3]),
        Rule("volleyball", strong: ["volleyball": 0.3]),
        Rule("hockey", strong: ["hockey": 0.3]),
        Rule("tennis", strong: ["tennis": 0.3]),
        Rule("golf", strong: ["golf": 0.3, "golf_course": 0.3]),
        Rule("gymnastics", strong: ["gymnastics": 0.3]),
        // What a family goes out to do, by Vision's own word for it.
        Rule("bowling", strong: ["bowling": 0.3]),
        Rule("ice_skating", strong: ["ice_skating": 0.3, "ice_skates": 0.3]),
        Rule("roller_skating", strong: ["rollerskating": 0.3, "rollerskates": 0.3]),
        Rule("go_karts", strong: ["go_kart": 0.3]),
        Rule("climbing", strong: ["rock_climbing": 0.3]),
        Rule("fishing", strong: ["fishing": 0.3]),
        // A game nobody can say more of: a stadium, a scoreboard, a meet, or
        // a sport with a ball in it. Never "sport" on its own, which Vision
        // says of anything active, life jackets included. Not an outing with
        // a ball in it, nor anything on or by the water.
        Rule("sports",
             strong: ["stadium": 0.3, "athletics": 0.3, "scoreboard": 0.3],
             supporting: ["sport": 0.4, "ball": 0.3, "ballgames": 0.3, "sports_equipment": 0.3],
             unless: ["bowling": 0.3, "billiards": 0.3, "ice_skating": 0.3, "rollerskating": 0.3,
                      "go_kart": 0.3, "rock_climbing": 0.3, "fishing": 0.3, "skateboarding": 0.3,
                      "skiing": 0.3, "snowboarding": 0.3,
                      "lifejacket": 0.3, "lake": 0.3, "water_body": 0.3, "boat": 0.3,
                      "watercraft": 0.3, "swimsuit": 0.3, "swimming": 0.3, "pool": 0.3,
                      "beach": 0.3, "watersport": 0.3, "wakeboarding": 0.3, "jetski": 0.3,
                      "surfing": 0.3, "kayak": 0.3, "canoe": 0.3]),

        // Outings.
        Rule("amusement_park",
             strong: ["amusement_park": 0.3, "rollercoaster": 0.3, "ferris_wheel": 0.3,
                      "carousel": 0.3, "carnival": 0.3, "fairground": 0.3, "circus": 0.3]),
        Rule("zoo", strong: ["zoo": 0.3]),
        Rule("aquarium", strong: ["aquarium": 0.3]),
        Rule("museum", strong: ["museum": 0.3]),
        Rule("parade", strong: ["parade": 0.3]),
        Rule("camping",
             strong: ["camping": 0.3, "tent": 0.4],
             supporting: ["fire": 0.3, "forest": 0.3, "lantern": 0.3, "backpack": 0.3,
                          "hiking": 0.3]),
        Rule("hiking",
             strong: ["hiking": 0.3, "trail": 0.4, "waterfall": 0.4, "canyon": 0.4],
             supporting: ["mountain": 0.3, "forest": 0.3, "backpack": 0.3]),
        // Not ice skating, which is mostly a rink indoors: see above.
        Rule("snow",
             strong: ["skiing": 0.3, "snowboarding": 0.3, "sledding": 0.3, "snowman": 0.3,
                      "winter_sport": 0.3],
             supporting: ["snow": 0.3, "ski_equipment": 0.3, "sled": 0.3, "snowball": 0.3,
                          "snowboard": 0.3]),
        Rule("beach",
             strong: ["beach": 0.3, "sandcastle": 0.3, "surfing": 0.3],
             supporting: ["shore": 0.3, "sand": 0.3, "ocean": 0.3, "surfboard": 0.3,
                          "swimsuit": 0.3, "seashell": 0.3, "windsurfing": 0.3,
                          "parasailing": 0.3, "palm_tree": 0.3]),
        Rule("pool",
             strong: ["pool": 0.4],
             supporting: ["swimming": 0.3, "swimsuit": 0.3]),
        // A day at a lake: on the boat, off the dock, behind the boat. Vision
        // has no word for water skiing or tubing; it says "watersport",
        // "wakeboarding" or "jetski", or only life jackets and water. Not the
        // ocean, a pool or a river: those are the beach, the pool and boating.
        Rule("lake",
             strong: ["lake": 0.5, "boathouse": 0.4],
             supporting: ["lake": 0.3, "dock": 0.3, "lifejacket": 0.3, "swimsuit": 0.3,
                          "swimming": 0.3, "water_body": 0.3, "boat": 0.3, "watercraft": 0.3,
                          "watersport": 0.3, "wakeboarding": 0.3, "jetski": 0.3],
             unless: ["ocean": 0.3, "beach": 0.3, "shore": 0.3, "sand": 0.3, "pool": 0.4,
                      "river": 0.4]),
        // Out on a boat. At a lake the day is a lake day, which takes in the
        // boat; see `events`.
        Rule("boating",
             strong: ["sailboat": 0.3, "kayak": 0.3, "canoe": 0.3, "speedboat": 0.3,
                      "rowboat": 0.3, "cruise_ship": 0.3, "yacht": 0.3, "houseboat": 0.3,
                      "jetski": 0.3, "rafting": 0.3],
             supporting: ["boat": 0.3, "watercraft": 0.3, "lake": 0.3, "river": 0.3, "dock": 0.3,
                          "pier": 0.3, "harbour": 0.3, "lifejacket": 0.3, "water_body": 0.3]),

        // Holiday evidence. Never a card on their own; see `holidayEvidence`.
        Rule("christmas",
             strong: ["christmas_tree": 0.3, "christmas_decoration": 0.3,
                      "santa_claus": 0.3, "wreath": 0.3, "gingerbread": 0.3],
             supporting: ["gift": 0.3, "candle": 0.3, "fireplace": 0.3, "snow": 0.3]),
        Rule("halloween",
             strong: ["jack_o_lantern": 0.3, "costume": 0.3],
             supporting: ["pumpkin": 0.3, "skeleton": 0.3, "mask": 0.3]),
        Rule("fireworks", strong: ["fireworks": 0.3, "sparkler": 0.3, "firecracker": 0.3]),
        Rule("flag", strong: ["flag": 0.4]),
        Rule("easter", strong: ["easter_egg": 0.3], supporting: ["egg": 0.4]),
        Rule("celebration",
             strong: ["celebration": 0.3],
             supporting: ["balloon": 0.3, "sparkler": 0.3, "cake": 0.4]),
        Rule("flowers", strong: ["rose": 0.4, "bouquet": 0.4]),
        Rule("meal",
             strong: ["dining_room": 0.4],
             supporting: ["food": 0.3, "table": 0.3, "tableware": 0.3, "pie": 0.3,
                          "restaurant": 0.3]),
    ]

    /// Labels that mark a photo as a record rather than a picture, tagged
    /// `utility`.
    ///
    /// The device also sends Vision's own `isUtility` from the aesthetics
    /// request, stored as sent. These catch what that misses. They're a tag
    /// rather than folded into the device's flag so that a rules change can
    /// take one back.
    static let utility: [String: Float] = [
        "screenshot": 0.3, "document": 0.4, "receipt": 0.3, "printed_page": 0.4,
        "handwriting": 0.5, "whiteboard": 0.5, "newspaper": 0.5,
    ]

    /// How many people make a gathering: enough that it isn't a portrait.
    static let gatheringPeople = 3

    static func tags(for labels: [ObservedLabel], peopleCount: Int) -> [String] {
        let confidence = Dictionary(
            labels.map { ($0.id, $0.confidence) }, uniquingKeysWith: max
        )
        func meets(_ thresholds: [String: Float]) -> [String] {
            thresholds.filter { confidence[$0.key, default: 0] >= $0.value }.map(\.key)
        }
        var tags: [String] = []
        for rule in rules where !meets(rule.strong).isEmpty
            || (meets(rule.supporting).count >= 2 && meets(rule.unless).isEmpty) {
            tags.append(rule.tag)
        }
        if peopleCount >= gatheringPeople { tags.append("gathering") }
        if !meets(utility).isEmpty { tags.append("utility") }
        return tags
    }

    // MARK: - Search

    /// How sure Vision has to have been of a label before a photo can be found
    /// by it. Lower than that and searching "dog" turns up every brown blur.
    static let searchConfidence: Float = 0.4

    /// Tags that are the server's bookkeeping rather than something a person
    /// would look for.
    static let unsearchable: Set<String> = ["utility", "gathering"]

    /// What a photo can be found by: its tags, and the labels Vision was fairly
    /// sure of. Stored as `media_observations.terms`, indexed.
    static func terms(labels: [ObservedLabel], tags: [String]) -> [String] {
        var terms = Set(tags.filter { !unsearchable.contains($0) })
        for label in labels where label.confidence >= searchConfidence {
            terms.insert(label.id)
        }
        return terms.sorted()
    }

    /// The single words a typed search can match: each term whole, and the
    /// words inside a compound one, so "cake" finds `birthday_cake` and "tree"
    /// finds `christmas_tree`. Fragments shorter than three letters are left
    /// out; the "o" in `jack_o_lantern` finds nothing anyone wants. Stored as
    /// `media_observations.words`, indexed.
    static func words(of terms: [String]) -> [String] {
        var words = Set<String>()
        for term in terms {
            words.insert(term)
            for part in term.split(separator: "_") where part.count >= 3 {
                words.insert(String(part))
            }
        }
        return words.sorted()
    }

    /// What search offers before anything is typed: things people look for in
    /// a family's photos, in groups so the offer can be varied — a pet, a
    /// trip, an occasion, rather than three kinds of dessert.
    ///
    /// A list of what to offer rather than of what not to. Ordered by how
    /// often they appear, Vision's labels for a family's photographs open on
    /// what's in every room: "conveyance" (its word for a vehicle), "portal"
    /// (a door), furniture, windows, curtains and cabinets, which is what the
    /// search screen used to list. Of 1,303 labels, these are the ones worth
    /// suggesting. Typing any label still finds it.
    ///
    /// Tags where a tag exists ("birthday", "beach"), since one takes more
    /// than a single label to earn. People are left out: they're in nearly
    /// every photo, and who someone is isn't what Vision says.
    static let suggestionGroups: [[String]] = [
        // Occasions.
        ["birthday", "christmas", "halloween", "easter", "wedding", "graduation",
         "fireworks", "concert", "parade"],
        // Days out.
        ["beach", "pool", "snow", "hiking", "camping", "boating", "amusement_park",
         "zoo", "aquarium", "museum", "playground", "park", "farm", "fishing",
         "skiing", "sledding"],
        // Sports and the like.
        ["sports", "soccer", "baseball", "softball", "basketball", "football",
         "volleyball", "hockey", "tennis", "golf", "gymnastics", "dancing", "ballet",
         "swimming", "cycling", "surfing", "skateboarding", "martial_arts", "bowling",
         "ice_skating", "roller_skating", "go_karts", "climbing"],
        // Animals.
        ["dog", "cat", "horse", "bird", "fish", "cow", "sheep", "goat", "pig", "deer",
         "rabbit", "squirrel", "butterfly", "turtle", "dolphin", "whale", "elephant",
         "giraffe", "zebra", "lion", "tiger", "bear", "penguin", "flamingo", "owl",
         "eagle", "frog", "snake", "lizard", "llama"],
        // Outdoors.
        ["sunset_sunrise", "mountain", "ocean", "lake", "river", "waterfall", "forest",
         "flower", "garden", "rainbow", "night_sky", "moon", "desert", "canyon",
         "island", "volcano", "glacier", "cliff", "cave", "aurora"],
        // Food and drink.
        ["meal", "food", "cake", "pizza", "ice_cream", "dessert", "cookie", "cupcake",
         "pancake", "sushi", "hamburger", "pasta", "salad", "fruit", "bread",
         "seafood", "taco", "donut", "pie", "coffee", "wine", "cocktail", "beer"],
        // Getting around.
        ["car", "boat", "airplane", "train", "bicycle", "motorcycle", "sailboat",
         "cruise_ship", "helicopter", "tractor", "firetruck", "bus"],
        // Sights.
        ["castle", "lighthouse", "bridge", "monument", "statue", "fountain",
         "ferris_wheel", "rollercoaster", "carousel", "stadium", "cityscape",
         "skyscraper", "pier", "ruins"],
    ]

    static let suggestable: Set<String> = Set(suggestionGroups.joined())

    /// The commonest suggestable term of each group, the commonest groups
    /// first, at most `limit` of them. `counts` is photos per term.
    static func suggestions(from counts: [String: Int], limit: Int) -> [String] {
        let best = suggestionGroups.compactMap { group in
            group.compactMap { term in counts[term].map { (term: term, count: $0) } }
                // Fewest photos is least; on a tie, the later name.
                .max { $0.count != $1.count ? $0.count < $1.count : $0.term > $1.term }
        }
        return best
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.term < $1.term }
            .prefix(limit)
            .map(\.term)
    }

    /// Words people type for a term that Vision or the vocabulary spells
    /// another way.
    static let synonyms: [String: String] = [
        "xmas": "christmas", "bday": "birthday", "puppy": "dog", "puppies": "dog",
        "kitty": "cat", "seaside": "beach", "sunset": "sunset_sunrise",
        "sunrise": "sunset_sunrise", "ski": "skiing",
    ]

    /// Names that Vision's own spelling of a term doesn't give.
    static let displayNames: [String: String] = [
        "sunset_sunrise": "Sunset",
    ]

    /// `birthday_cake` → "Birthday cake".
    static func spoken(_ term: String) -> String {
        if let name = displayNames[term] { return name }
        let words = term.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - Tags to occasions

    /// Something a day, or a trip, can turn out to have been.
    struct Event: Sendable {
        /// The tag that is its evidence.
        let tag: String
        /// What a day of it is called, sentence case like every other title on
        /// the page. The place follows: "Birthday party in Culpeper".
        let title: String
        /// What a trip of it is called, or nil when it doesn't name a trip. A
        /// birthday on vacation was still the vacation.
        let tripTitle: String?
        /// "Beach trip *to* Duck", but "Wedding *in* Charleston".
        let tripPreposition: String
        /// The share of a day's usable photos that must show it, and the
        /// fewest photos that will do. A birthday is a few minutes of candles
        /// in an afternoon of photographs; a beach day is the beach all day.
        let minShare: Double
        let minPhotos: Int

        init(
            _ tag: String, _ title: String, trip: String? = nil, preposition: String = "to",
            share: Double, photos: Int = 3
        ) {
            self.tag = tag
            self.title = title
            self.tripTitle = trip
            self.tripPreposition = preposition
            self.minShare = share
            self.minPhotos = photos
        }
    }

    /// In priority order. Where a day qualifies as several, the first wins:
    /// the wedding over the beach it was held on.
    static let events: [Event] = [
        Event("wedding", "Wedding", trip: "Wedding", preposition: "in", share: 0.15),
        Event("graduation", "Graduation", trip: "Graduation", preposition: "in",
              share: 0.1, photos: 2),
        Event("birthday", "Birthday party", share: 0.1, photos: 2),
        Event("concert", "Concert", share: 0.25),
        Event("soccer", "Soccer game", share: 0.25),
        Event("baseball", "Baseball game", share: 0.25),
        Event("softball", "Softball game", share: 0.25),
        Event("basketball", "Basketball game", share: 0.25),
        Event("football", "Football game", share: 0.25),
        Event("volleyball", "Volleyball game", share: 0.25),
        Event("hockey", "Hockey game", share: 0.25),
        Event("tennis", "Tennis", share: 0.25),
        Event("golf", "Golf", trip: "Golf trip", share: 0.25),
        Event("gymnastics", "Gymnastics meet", share: 0.25),
        Event("bowling", "Bowling", share: 0.25),
        Event("ice_skating", "Ice skating", share: 0.25),
        Event("roller_skating", "Roller skating", share: 0.25),
        Event("go_karts", "Go-karts", share: 0.25),
        Event("climbing", "Climbing", share: 0.25),
        Event("fishing", "Fishing", trip: "Fishing trip", share: 0.25),
        Event("sports", "Game day", share: 0.3, photos: 4),
        Event("amusement_park", "Amusement park", trip: "Theme park trip", share: 0.2),
        Event("zoo", "A day at the zoo", share: 0.2),
        Event("aquarium", "The aquarium", share: 0.2),
        Event("parade", "Parade", share: 0.2),
        Event("museum", "Museum visit", share: 0.25),
        Event("camping", "Camping", trip: "Camping trip", share: 0.2),
        Event("snow", "Snow day", trip: "Snow trip", share: 0.3),
        Event("hiking", "A hike", trip: "Hiking trip", share: 0.3),
        Event("beach", "Beach day", trip: "Beach trip", share: 0.3),
        Event("lake", "Lake day", trip: "Lake trip", share: 0.3),
        Event("pool", "Pool day", share: 0.3),
        Event("boating", "Boating", trip: "Boating trip", share: 0.3),
    ]

    /// What makes a day what it was however little of it it took: a
    /// birthday is a few minutes of candles in an afternoon.
    static let lifeEvents: Set<String> = ["wedding", "graduation", "birthday"]

    /// Says only that a game was played, so it names a day only when
    /// nothing else can.
    static let anyGame = "sports"

    /// What a day, or a trip, was.
    ///
    /// A wedding, a graduation or a birthday first, in that order, however
    /// little of the day it took, with one exception: a graduation and a
    /// wedding both run to gowns, ceremonies and people in their best
    /// clothes, so where both clear, the one more of the photos show is the
    /// one it was.
    ///
    /// Otherwise what most of the photos show, of everything that cleared its
    /// bar: the theme is what the day was about, not whichever rule came
    /// first. A lake day whose life jackets looked sporty was "Game day" when
    /// the first rule won (his library, 2026-11-11). Ties go to the earlier
    /// in `events`, and "Game day" only names a day nothing else does.
    static func event(clearing: (Event) -> Bool, count: (String) -> Int) -> Event? {
        let cleared = events.filter(clearing)
        if let first = cleared.first(where: { lifeEvents.contains($0.tag) }) {
            if first.tag == "wedding",
               let graduation = cleared.first(where: { $0.tag == "graduation" }),
               count("graduation") >= count("wedding") {
                return graduation
            }
            return first
        }
        // `max` keeps the first of equals, so a tie goes to the earlier.
        return cleared.filter { $0.tag != anyGame }.max { count($0.tag) < count($1.tag) }
            ?? cleared.first { $0.tag == anyGame }
    }

    /// A trip takes a kind on a smaller share than a day: a week away is
    /// several things, and a beach trip still has its drives and dinners.
    static let tripShare = 0.2

    /// What a holiday needs to have looked like before it gets an album.
    ///
    /// The date alone used to be enough: any Christmas Day with a few photos
    /// became "Christmas". Not every family celebrates every holiday, and an
    /// album that assumes they do says something about them it has no right
    /// to. So a holiday now needs to look like itself (a tree, a costume,
    /// fireworks). Family holidays with no symbol of their own need a
    /// gathering. Easter and Christmas are held to their own symbols, never to
    /// a crowd, because a family lunch says nothing about faith.
    ///
    /// A holiday missing from this table keeps the old rule: the date is
    /// enough.
    struct Evidence: Sendable {
        let tag: String
        let minPhotos: Int
        let minShare: Double
    }

    static let holidayEvidence: [String: [Evidence]] = {
        let christmas = [Evidence(tag: "christmas", minPhotos: 2, minShare: 0.05)]
        let gathering = Evidence(tag: "gathering", minPhotos: 3, minShare: 0.2)
        let fireworks = Evidence(tag: "fireworks", minPhotos: 2, minShare: 0.05)
        let flag = Evidence(tag: "flag", minPhotos: 2, minShare: 0.05)
        let celebration = Evidence(tag: "celebration", minPhotos: 2, minShare: 0.05)
        let flowers = Evidence(tag: "flowers", minPhotos: 2, minShare: 0.05)
        return [
            "Christmas Eve": christmas,
            "Christmas": christmas,
            "Halloween": [Evidence(tag: "halloween", minPhotos: 2, minShare: 0.05)],
            "Easter": [Evidence(tag: "easter", minPhotos: 2, minShare: 0.05)],
            "Fourth of July": [fireworks, flag, gathering],
            "New Year's Eve": [fireworks, celebration, gathering],
            "New Year's Day": [fireworks, celebration, gathering],
            "Thanksgiving": [gathering, Evidence(tag: "meal", minPhotos: 3, minShare: 0.15)],
            "Mother's Day": [gathering, flowers],
            "Father's Day": [gathering],
            "Memorial Day": [gathering, flag],
            "Labor Day": [gathering, flag],
            "Valentine's Day": [flowers, celebration],
        ]
    }()

    // MARK: - Keeping stored tags current

    /// Re-derives the tags of every photo stored under an older vocabulary.
    ///
    /// Runs once at boot, in the background, in pages, so a rules change
    /// reaches the whole library without anyone re-analyzing a photograph.
    static func retag(on app: Application) async {
        struct Row: Decodable {
            let userID: UUID
            let sha256: String
            let labels: String
            let peopleCount: Int
        }
        let sql = app.sql
        var updated = 0
        do {
            while true {
                let rows = try await sql.raw("""
                    SELECT user_id AS "userID", sha256, labels::text AS labels,
                           people_count AS "peopleCount"
                    FROM media_observations
                    WHERE vocabulary_version < \(bind: version)
                    LIMIT 500
                    """).all(decoding: Row.self)
                if rows.isEmpty { break }
                for row in rows {
                    let labels = (try? JSONDecoder().decode(
                        [ObservedLabel].self, from: Data(row.labels.utf8)
                    )) ?? []
                    let tags = tags(for: labels, peopleCount: row.peopleCount)
                    let terms = terms(labels: labels, tags: tags)
                    try await sql.raw("""
                        UPDATE media_observations
                        SET tags = \(bind: tags),
                            terms = \(bind: terms),
                            words = \(bind: words(of: terms)),
                            vocabulary_version = \(bind: version)
                        WHERE user_id = \(bind: row.userID) AND sha256 = \(bind: row.sha256)
                        """).run()
                }
                updated += rows.count
            }
            if updated > 0 {
                app.logger.info("curation: retagged \(updated) photos for vocabulary \(version)")
            }
        } catch {
            app.logger.error("curation: retagging stopped: \(error)")
        }
    }
}
