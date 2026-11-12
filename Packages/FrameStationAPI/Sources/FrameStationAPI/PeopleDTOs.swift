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
    /// Who they are to the library's owner, as a `Relationship` raw value.
    /// A string rather than the enum, so a word a newer app adds never stops
    /// an older one reading the person. See `relationship`.
    public let relation: String?
    /// The library's owner themself: "This is me".
    public let isMe: Bool
    /// Where they go on the People page, as a `PersonTier` raw value: the
    /// NAS decides who's suggested for a name and who waits behind More
    /// People. Nil from a NAS older than tiers. See `place`.
    public let tier: String?
    /// For someone unnamed, the named person the NAS thinks they may be:
    /// one question for the whole group, answered with
    /// `PersonMaybeAnswer`. Nil when there's nothing to ask, for anyone
    /// named, and from a NAS older than these questions.
    public let maybe: PersonMaybe?

    public var relationship: Relationship? { relation.flatMap(Relationship.init(rawValue:)) }

    /// Where they go: an older NAS's unnamed people are all shown, as before.
    public var place: PersonTier {
        tier.flatMap(PersonTier.init(rawValue:)) ?? (name != nil || isMe ? .named : .suggested)
    }

    public init(
        id: UUID, name: String?, photoCount: Int, face: String, questions: Int = 0,
        relation: String? = nil, isMe: Bool = false, tier: String? = nil, maybe: PersonMaybe? = nil
    ) {
        self.id = id
        self.name = name
        self.photoCount = photoCount
        self.face = face
        self.questions = questions
        self.relation = relation
        self.isMe = isMe
        self.tier = tier
        self.maybe = maybe
    }

    enum CodingKeys: String, CodingKey {
        case id, name, photoCount, face, questions, relation, isMe, tier, maybe
    }

    /// What's been added since the first People server is read as absent
    /// rather than failing the person, so an app updated before its NAS
    /// still draws everyone.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        photoCount = try c.decode(Int.self, forKey: .photoCount)
        face = try c.decode(String.self, forKey: .face)
        questions = try c.decodeIfPresent(Int.self, forKey: .questions) ?? 0
        relation = try c.decodeIfPresent(String.self, forKey: .relation)
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        maybe = try c.decodeIfPresent(PersonMaybe.self, forKey: .maybe)
    }
}

/// The named person an unnamed one may be: "Is this Emma?" for the whole
/// group. Always someone in the same library, named and shown.
public struct PersonMaybe: Codable, Sendable, Hashable {
    /// The named person.
    public let id: UUID
    public let name: String
    /// Which face stands for them, the same key as their own
    /// `PersonSummary.face`.
    public let face: String

    public init(id: UUID, name: String, face: String) {
        self.id = id
        self.name = name
        self.face = face
    }
}

/// The owner's answer to `PersonSummary.maybe`, sent for the unnamed person.
/// Yes is the same as merging the whole group into the named person. No says
/// none of the group's faces is them, so the NAS never puts those faces with
/// them or asks about the group for them again.
public struct PersonMaybeAnswer: Codable, Sendable, Hashable {
    /// The named person the app showed, `PersonMaybe.id`.
    public let personID: UUID
    public let isPerson: Bool

    public init(personID: UUID, isPerson: Bool) {
        self.personID = personID
        self.isPerson = isPerson
    }
}

/// Where someone goes on the People page. The NAS decides; see
/// `PeopleController.Tier`.
public enum PersonTier: String, Codable, Sendable {
    /// Named, or the owner: on top.
    case named
    /// Unnamed, but seen often over many days: under the named.
    case suggested
    /// Seen more than once: behind More People.
    case more
}

/// Who someone is to the library's owner, in the word the owner chose. The
/// NAS uses the `kind` (family or not, the owner's children), and titles use
/// the person's name, never this word. Never guessed: only ever what the
/// owner picked.
public enum Relationship: String, Codable, Sendable, CaseIterable, Identifiable {
    case partner, husband, wife
    case son, daughter, child
    case mom, dad, parent
    case brother, sister, sibling
    case grandma, grandpa, grandparent
    case grandson, granddaughter, grandchild
    case aunt, uncle
    case niece, nephew
    case cousin
    case inLaw
    case family
    case friend

    public var id: String { rawValue }

    public enum Kind: String, Sendable, CaseIterable {
        case partner, child, parent, sibling, grandparent, grandchild
        case auntOrUncle, nieceOrNephew, cousin, inLaw, family, friend

        /// The kinds in the order a picker lists them.
        public var words: [Relationship] {
            Relationship.allCases.filter { $0.kind == self }
        }
    }

    public var kind: Kind {
        switch self {
        case .partner, .husband, .wife: return .partner
        case .son, .daughter, .child: return .child
        case .mom, .dad, .parent: return .parent
        case .brother, .sister, .sibling: return .sibling
        case .grandma, .grandpa, .grandparent: return .grandparent
        case .grandson, .granddaughter, .grandchild: return .grandchild
        case .aunt, .uncle: return .auntOrUncle
        case .niece, .nephew: return .nieceOrNephew
        case .cousin: return .cousin
        case .inLaw: return .inLaw
        case .family: return .family
        case .friend: return .friend
        }
    }

    /// Everyone but friends.
    public var isFamily: Bool { kind != .friend }

    /// The word as it's shown: "Mom", "In-Law", "Family".
    public var word: String {
        switch self {
        case .inLaw: return "In-Law"
        case .family: return "Family"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Who someone is to the owner. Nil takes it back.
public struct PersonRelationRequest: Codable, Sendable, Hashable {
    public let relation: String?

    public init(relation: Relationship?) {
        self.relation = relation?.rawValue
    }
}

/// "This is me", or not. One person at most is.
public struct PersonIsMeRequest: Codable, Sendable, Hashable {
    public let isMe: Bool

    public init(isMe: Bool) {
        self.isMe = isMe
    }
}

// MARK: - The people in one photo

/// A face the NAS found in one photo or video, and who it is, for the
/// Information panel. A video lists each person once.
public struct PhotoFace: Codable, Sendable, Hashable, Identifiable {
    /// Which face in the file, for its picture and for correcting it.
    public let ordinal: Int
    /// Nil for a face that isn't anyone yet.
    public let personID: UUID?
    public let name: String?
    public let relation: String?
    public let isMe: Bool
    /// The owner said so, rather than the NAS.
    public let isConfirmed: Bool

    public var id: Int { ordinal }

    public init(
        ordinal: Int, personID: UUID?, name: String?, relation: String?, isMe: Bool, isConfirmed: Bool
    ) {
        self.ordinal = ordinal
        self.personID = personID
        self.name = name
        self.relation = relation
        self.isMe = isMe
        self.isConfirmed = isConfirmed
    }
}

public struct PhotoPeopleResponse: Codable, Sendable, Hashable {
    public let faces: [PhotoFace]

    public init(faces: [PhotoFace]) {
        self.faces = faces
    }
}

/// Who a face in a photo is: someone already in People, someone new by
/// name, or, with both nil, nobody the NAS should keep it with ("Not
/// Emma"). Kept for good: the NAS learns from it and never undoes it.
public struct AssignFaceRequest: Codable, Sendable, Hashable {
    public let personID: UUID?
    public let newName: String?

    public init(personID: UUID? = nil, newName: String? = nil) {
        self.personID = personID
        self.newName = newName
    }
}

// MARK: - Together

/// Two people often in the same photos: an album of the photos they're both
/// in, the way Photos keeps groups under People.
public struct PeopleTogether: Codable, Sendable, Hashable, Identifiable {
    /// The two, in a fixed order.
    public let people: [UUID]
    public let photoCount: Int

    /// Its collection key, `CollectionKind.together`.
    public var key: String { people.map(\.uuidString).joined(separator: ",") }
    public var id: String { key }

    public init(people: [UUID], photoCount: Int) {
        self.people = people
        self.photoCount = photoCount
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
