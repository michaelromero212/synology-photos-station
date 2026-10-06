import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension PlacesResponse: @retroactive Content {}
extension ThingsResponse: @retroactive Content {}
extension SearchResults: @retroactive Content {}

/// Search: where a photo was taken, when, and what's in it.
///
/// Place is a column the library already has for every photo with GPS, filled
/// in at import by the offline geocoder. What's in a photo comes from what the
/// person's own devices recognized (`media_observations.terms`, see
/// `CurationVocabulary.terms`), so it covers the photos those devices have
/// analyzed and nothing else. Neither needs an ML runtime here, and nothing
/// leaves the NAS.
struct SearchController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("spaces", ":spaceID", "places", use: places)
        protected.get("spaces", ":spaceID", "things", use: things)
        protected.get("spaces", ":spaceID", "search", use: search)
    }

    // MARK: - Things

    /// What this library's photos were seen to show, commonest first: the
    /// search screen's other list, beside places.
    ///
    /// Only what the caller's own devices recognized, so a photo someone else
    /// shared into a library shows up here once one of the caller's devices
    /// has analyzed a copy. Labels true of nearly everything ("outdoor", "sky")
    /// are left out of the landing list, since offering them helps nobody, but
    /// typing one still finds it.
    @Sendable
    func things(req: Request) async throws -> ThingsResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.placesPageSize, 1), 500)
        let typed = (req.query[String.self, at: "q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        guard try await CurationController.isEnabled(userID: device.userID, on: req.sql) else {
            return ThingsResponse(things: [], total: 0)
        }

        // "birthday cake" is stored as birthday_cake.
        let normalized = typed.replacingOccurrences(of: " ", with: "_")
        let pattern = normalized.isEmpty ? "%" : "%\(escapeForLike(normalized))%"
        let skipped = typed.isEmpty ? CurationVocabulary.tooGeneral.sorted() : []

        struct ThingRow: Decodable { let term: String; let count: Int }
        let rows = try await req.sql.raw("""
            SELECT t.term, count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN media_observations o
              ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            CROSS JOIN LATERAL unnest(o.terms) AS t(term)
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND t.term LIKE \(bind: pattern)
              AND NOT (t.term = ANY(\(bind: skipped)::text[]))
            GROUP BY t.term
            ORDER BY count DESC, t.term
            LIMIT \(bind: limit)
            """).all(decoding: ThingRow.self)

        struct CountRow: Decodable { let total: Int }
        let total = try await req.sql.raw("""
            SELECT count(DISTINCT t.term)::int AS total
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            JOIN media_observations o
              ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            CROSS JOIN LATERAL unnest(o.terms) AS t(term)
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND t.term LIKE \(bind: pattern)
              AND NOT (t.term = ANY(\(bind: skipped)::text[]))
            """).first(decoding: CountRow.self)?.total ?? 0

        return ThingsResponse(
            things: rows.map {
                ThingSummary(term: $0.term, name: CurationVocabulary.spoken($0.term), count: $0.count)
            },
            total: total
        )
    }

    // MARK: - Places

    private struct PlaceRow: Decodable {
        let name: String
        let count: Int
    }

    /// The places this space has photos from, commonest first.
    ///
    /// Commonest rather than alphabetical because the top of this list is the
    /// screen you land on before typing anything: it should open on where the
    /// family actually lives and holidays, not wherever happens to start with A.
    ///
    /// Bounded, and that matters more than it sounds. A library accumulates one
    /// row per town anyone ever drove through, so ordering by count produces a
    /// genuinely useful handful followed by a very long tail of places with a
    /// count of one — and the tail is most of the list *and* most of the
    /// payload. `limit` is what lets the landing screen ask for the handful.
    ///
    /// `q` filters by name, so a caller holding only the top twelve can still
    /// offer search over all of them without downloading the vocabulary first.
    /// Sorted by count here too: typing "spring" should offer the Springfield
    /// with four hundred photos before the one with two.
    @Sendable
    func places(req: Request) async throws -> PlacesResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.placesPageSize, 1), 2000)
        let sort = req.query[String.self, at: "sort"] ?? "count"

        let query = (req.query[String.self, at: "q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Matches everything when nothing was typed, so one query serves both
        // the landing screen and search rather than two that can disagree.
        let pattern = query.isEmpty ? "%" : "%\(escapeForLike(query))%"

        // Alphabetical is the right order for the full list, where the job is
        // finding a name you already have in mind rather than being shown what
        // you shoot most. Two screens, two jobs, two orders.
        let ordering = sort == "name"
            ? "name ASC"
            : "count DESC, name ASC"

        let rows = try await req.sql.raw("""
            SELECT a.place_name AS name, count(*)::int AS count
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            GROUP BY a.place_name
            ORDER BY \(unsafeRaw: ordering)
            LIMIT \(bind: limit)
            """).all(decoding: PlaceRow.self)

        // Counted separately rather than inferred from `rows`, which is capped:
        // the "See All" row has to be able to say 340 while holding 12.
        struct CountRow: Decodable { let total: Int }
        let total = try await req.sql.raw("""
            SELECT count(DISTINCT a.place_name)::int AS total
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND a.place_name IS NOT NULL
              AND \(unsafeRaw: TimelineController.visible)
              AND a.place_name ILIKE \(bind: pattern)
            """).first(decoding: CountRow.self)?.total ?? 0

        return PlacesResponse(
            places: rows.map { PlaceSummary(name: $0.name, count: $0.count) },
            total: total
        )
    }

    /// What the landing screen asks for when it doesn't say.
    static let placesPageSize = 12

    // MARK: - Search

    /// How many results one page carries.
    static let pageSize = 120

    /// `q` is whatever was typed, read by `plan`. `place` is the place-only
    /// search older apps send, unchanged: one place name, matched as a
    /// substring.
    @Sendable
    func search(req: Request) async throws -> SearchResults {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.pageSize, 1), 500)

        let text = (req.query[String.self, at: "q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let place = (req.query[String.self, at: "place"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !place.isEmpty else {
            return SearchResults(items: [], total: 0, nextOffset: nil)
        }

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        let filters: SQLQueryString
        if !text.isEmpty {
            guard let planned = try await plan(text, userID: device.userID, on: req.sql) else {
                return SearchResults(items: [], total: 0, nextOffset: nil)
            }
            filters = planned
        } else {
            // Substring, so typing "Virginia" finds "Culpeper County, Virginia"
            // and picking a place off the list finds exactly itself. `ILIKE`
            // with a leading wildcard cannot use a btree index, which is fine
            // at this scale — a sequential scan over one text column for a
            // library of this size is milliseconds, and a trigram index is one
            // migration away if that ever stops being true.
            filters = "AND a.place_name ILIKE \(bind: "%\(escapeForLike(place))%")"
        }

        // At most one row per photo: observations are keyed by (person, file).
        struct CountRow: Decodable { let total: Int }
        let total = try await req.sql.raw("""
            SELECT count(*)::int AS total
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN media_observations o
                   ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              \(filters)
            """).first(decoding: CountRow.self)?.total ?? 0

        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
            FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            LEFT JOIN media_observations o
                   ON o.user_id = \(bind: device.userID) AND o.sha256 = a.sha256
            WHERE sa.space_id = \(bind: spaceID)
              AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
              \(filters)
            ORDER BY \(unsafeRaw: TimelineController.localTime) DESC, sa.id
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: TimelineController.ItemRow.self)

        let consumed = offset + rows.count
        return SearchResults(
            items: rows.map { $0.toItem() },
            total: total,
            nextOffset: consumed < total ? consumed : nil
        )
    }

    // MARK: - Reading what was typed

    /// Turns what was typed into filters, every one of which has to hold.
    ///
    /// A year ("2024") narrows to that year. Any other word can mean what's in
    /// a photo or where it was taken, and either will do. So "beach" finds a
    /// beach in a photo and photos taken at Virginia Beach, and "dog Culpeper"
    /// finds the dog photographed in Culpeper. Rather than guess which "Duck"
    /// was meant (the bird or the town), it finds both. A month name can also
    /// mean the month: "july 2024".
    ///
    /// Nil when nothing usable was typed.
    private func plan(
        _ text: String, userID: UUID, on sql: any SQLDatabase
    ) async throws -> SQLQueryString? {
        var words = Self.words(in: text)
        var years: [Int] = []
        words.removeAll { word in
            guard word.count == 4, let year = Int(word), (1900...2100).contains(year) else {
                return false
            }
            years.append(year)
            return true
        }
        guard !words.isEmpty || !years.isEmpty else { return nil }

        // With curation off, a word means a place or a month and nothing more.
        let curated = try await CurationController.isEnabled(userID: userID, on: sql)
        let local = TimelineController.localTime
        var filters: SQLQueryString = ""
        var index = 0
        while index < words.count {
            var phrase = words[index]
            // A single word is matched against the words inside every term,
            // so "cake" finds `birthday_cake`. A pair that is one term is
            // matched against the terms themselves, which is more exact.
            var shown: SQLQueryString =
                "o.words && \(bind: curated ? Self.termCandidates(phrase) : [])::text[]"
            // Two words that are one thing to Vision, such as "birthday cake"
            // or "christmas tree", are taken together when this person's
            // photos hold the pair as one term.
            if curated, index + 1 < words.count {
                let compound = Self.termForm(words[index]) + "_" + Self.termForm(words[index + 1])
                if try await hasTerm(compound, userID: userID, on: sql) {
                    phrase = words[index] + " " + words[index + 1]
                    shown = "o.terms && ARRAY[\(bind: compound)]::text[]"
                    index += 1
                }
            }
            index += 1

            let pattern = "%\(escapeForLike(phrase))%"
            var either: SQLQueryString = "\(shown) OR a.place_name ILIKE \(bind: pattern)"
            if let month = Self.months[phrase] {
                either = "\(either) OR EXTRACT(MONTH FROM \(unsafeRaw: local))::int = \(bind: month)"
            }
            filters = "\(filters) AND (\(either))"
        }
        if !years.isEmpty {
            filters = "\(filters) AND EXTRACT(YEAR FROM \(unsafeRaw: local))::int = ANY(\(bind: years))"
        }
        return filters
    }

    /// Lowercased words. Apostrophes and hyphens stay inside a word, since
    /// they're part of place names.
    static func words(in text: String) -> [String] {
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’-"))
            .inverted
        return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// A word spelled the way terms are: "valentine's" → "valentines".
    static func termForm(_ word: String) -> String {
        word.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Every term a word could stand for: itself, the word people type for it
    /// ("xmas"), and its singular ("dogs", "parties", "beaches").
    static func termCandidates(_ word: String) -> [String] {
        let base = termForm(word)
        var candidates: Set<String> = [base]
        if let synonym = CurationVocabulary.synonyms[base] { candidates.insert(synonym) }
        if base.hasSuffix("ies"), base.count > 4 { candidates.insert(String(base.dropLast(3)) + "y") }
        if base.hasSuffix("es"), base.count > 3 { candidates.insert(String(base.dropLast(2))) }
        if base.hasSuffix("s"), base.count > 3 { candidates.insert(String(base.dropLast())) }
        return candidates.sorted()
    }

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// Whether any of this person's photos carry a term. An index lookup.
    private func hasTerm(_ term: String, userID: UUID, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 AS found FROM media_observations
            WHERE user_id = \(bind: userID) AND terms @> ARRAY[\(bind: term)]::text[]
            LIMIT 1
            """).first() != nil
    }

    /// `%`, `_` and `\` are wildcards to `LIKE`. Someone searching for a place
    /// with an underscore in it should find that place, not every place.
    private func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
