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
    static let version = 3

    // MARK: - Labels to tags

    /// One tag, and what earns it.
    struct Rule: Sendable {
        let tag: String
        /// Any one of these, at or above its confidence, is enough.
        let strong: [String: Float]
        /// Otherwise two of these together are.
        let supporting: [String: Float]

        init(_ tag: String, strong: [String: Float], supporting: [String: Float] = [:]) {
            self.tag = tag
            self.strong = strong
            self.supporting = supporting
        }
    }

    static let rules: [Rule] = [
        // Occasions.
        Rule("birthday",
             strong: ["birthday_cake": 0.3],
             supporting: ["candle": 0.3, "balloon": 0.3, "cake": 0.4, "cupcake": 0.4,
                          "gift": 0.4, "celebration": 0.3]),
        Rule("wedding",
             strong: ["wedding": 0.3, "wedding_dress": 0.3, "bride": 0.3, "wedding_cake": 0.3],
             supporting: ["groom": 0.3, "bridesmaid": 0.3, "bouquet": 0.3, "tuxedo": 0.3,
                          "gown": 0.3, "ceremony": 0.3]),
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
        Rule("sports",
             strong: ["sport": 0.4, "stadium": 0.3, "athletics": 0.3, "scoreboard": 0.3],
             supporting: ["ball": 0.3, "ballgames": 0.3, "sports_equipment": 0.3]),

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
        Rule("snow",
             strong: ["skiing": 0.3, "snowboarding": 0.3, "sledding": 0.3, "snowman": 0.3,
                      "winter_sport": 0.3, "ice_skating": 0.3],
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
        Rule("boating",
             strong: ["sailboat": 0.3, "kayak": 0.3, "canoe": 0.3, "speedboat": 0.3,
                      "rowboat": 0.3, "cruise_ship": 0.3],
             supporting: ["boat": 0.3, "lake": 0.3, "river": 0.3]),

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
        for rule in rules where !meets(rule.strong).isEmpty || meets(rule.supporting).count >= 2 {
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

    /// Labels true of nearly every photo, so not worth offering as a
    /// suggestion. Typing one still searches for it.
    static let tooGeneral: Set<String> = [
        "outdoor", "sky", "structure", "material", "textile", "people", "adult",
        "clothing", "land", "plant", "machine", "liquid", "water", "wood_processed",
        "interior_room", "building", "cloudy", "blue_sky", "vegetation", "grass",
        "foliage", "tree",
    ]

    /// Words people type for a term that Vision or the vocabulary spells
    /// another way.
    static let synonyms: [String: String] = [
        "xmas": "christmas", "bday": "birthday", "puppy": "dog", "puppies": "dog",
        "kitty": "cat", "seaside": "beach", "sunset": "sunset_sunrise",
        "sunrise": "sunset_sunrise", "ski": "skiing",
    ]

    /// `birthday_cake` → "Birthday cake".
    static func spoken(_ term: String) -> String {
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
        Event("pool", "Pool day", share: 0.3),
        Event("boating", "On the water", trip: "Boating trip", share: 0.3),
    ]

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
