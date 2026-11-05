import Foundation

// MARK: - People
//
// The people in a person's own library, as the NAS groups their faces and as
// they name them. Names belong to the person who gave them. Nothing here ever
// carries a face's numbers: an app gets names, counts, which photos, and face
// pictures cropped from the person's own photos. See NAS-ANALYSIS.md §6.

/// One person, for the People row and their page.
public struct PersonSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Nil until the library's owner names them.
    public let name: String?
    public let photoCount: Int
    /// Which face stands for them, as an opaque key; changes when that face
    /// does, so a cached picture is never the wrong one.
    public let face: String
    /// "Is this Emma?" questions waiting, for someone named.
    public let questions: Int

    public init(id: UUID, name: String?, photoCount: Int, face: String, questions: Int = 0) {
        self.id = id
        self.name = name
        self.photoCount = photoCount
        self.face = face
        self.questions = questions
    }
}

public struct PeopleResponse: Codable, Sendable, Hashable {
    public let people: [PersonSummary]

    public init(people: [PersonSummary]) {
        self.people = people
    }
}

/// Names someone, renames them, or, with nil or empty, takes the name back.
public struct NamePersonRequest: Codable, Sendable, Hashable {
    public let name: String?

    public init(name: String?) {
        self.name = name
    }
}

/// "Same person": everything of `otherID` becomes this person's. The owner's
/// call, so it may join two people they named.
public struct MergePeopleRequest: Codable, Sendable, Hashable {
    public let otherID: UUID

    public init(otherID: UUID) {
        self.otherID = otherID
    }
}

/// "Not this person", for these photos. They never join this person again.
public struct PersonPhotosRequest: Codable, Sendable, Hashable {
    public let assetIDs: [UUID]

    public init(assetIDs: [UUID]) {
        self.assetIDs = assetIDs
    }
}

/// A face the NAS thinks may be this person: one photo, and which face in it.
public struct PersonSuggestion: Codable, Sendable, Hashable, Identifiable {
    public let assetID: UUID
    public let ordinal: Int

    public var id: String { "\(assetID)#\(ordinal)" }

    public init(assetID: UUID, ordinal: Int) {
        self.assetID = assetID
        self.ordinal = ordinal
    }
}

public struct PersonSuggestionsResponse: Codable, Sendable, Hashable {
    public let person: PersonSummary
    /// Closest first.
    public let suggestions: [PersonSuggestion]

    public init(person: PersonSummary, suggestions: [PersonSuggestion]) {
        self.person = person
        self.suggestions = suggestions
    }
}

/// Yes or no to one "Is this Emma?".
public struct AnswerSuggestionRequest: Codable, Sendable, Hashable {
    public let assetID: UUID
    public let ordinal: Int
    public let isPerson: Bool

    public init(assetID: UUID, ordinal: Int, isPerson: Bool) {
        self.assetID = assetID
        self.ordinal = ordinal
        self.isPerson = isPerson
    }
}
