import FrameStationAPI
import Foundation

// MARK: - People
//
// The people the NAS found in this person's own library, and their say over
// it: names, "Is this Emma?", "Not Emma", "Same person". Names, counts, which
// photos and pictures of faces; never a face's numbers. See NAS-ANALYSIS.md §6.
//
// Every call is for the caller's own personal library. Any other library, or
// one the NAS doesn't analyze, answers 404.

extension FrameStationClient {
    /// Everyone, named first and then by how many photos they're in. The
    /// Albums page carries the first few in `CollectionsResponse.people`.
    public func people(spaceID: UUID) async throws -> [PersonSummary] {
        let response: PeopleResponse = try await get("v1/spaces/\(spaceID)/people")
        return response.people
    }

    /// Names someone, renames them, or, with nil or an empty name, takes the
    /// name back.
    public func namePerson(
        spaceID: UUID, personID: UUID, name: String?
    ) async throws -> PersonSummary {
        try await put(
            "v1/spaces/\(spaceID)/people/\(personID)", body: NamePersonRequest(name: name)
        )
    }

    /// "Same person": everything of `otherID` becomes `personID`'s, and
    /// `otherID` is gone. `personID` keeps its name, or takes the other's if
    /// it has none.
    public func mergePeople(
        spaceID: UUID, personID: UUID, otherID: UUID
    ) async throws -> PersonSummary {
        try await post(
            "v1/spaces/\(spaceID)/people/\(personID)/merge",
            body: MergePeopleRequest(otherID: otherID)
        )
    }

    /// "Not this person", for these photos. They never join them again.
    public func removeFromPerson(
        spaceID: UUID, personID: UUID, assetIDs: [UUID]
    ) async throws -> PersonSummary {
        try await post(
            "v1/spaces/\(spaceID)/people/\(personID)/remove",
            body: PersonPhotosRequest(assetIDs: assetIDs)
        )
    }

    /// The faces the NAS would like to ask about, closest first.
    public func personSuggestions(
        spaceID: UUID, personID: UUID
    ) async throws -> PersonSuggestionsResponse {
        try await get("v1/spaces/\(spaceID)/people/\(personID)/suggestions")
    }

    /// Yes or no to one "Is this Emma?".
    @discardableResult
    public func answerSuggestion(
        spaceID: UUID, personID: UUID, _ suggestion: PersonSuggestion, isPerson: Bool
    ) async throws -> PersonSummary {
        try await post(
            "v1/spaces/\(spaceID)/people/\(personID)/suggestions",
            body: AnswerSuggestionRequest(
                assetID: suggestion.assetID, ordinal: suggestion.ordinal, isPerson: isPerson
            )
        )
    }

    /// Who someone is to the owner, or nil to take it back.
    public func setRelationship(
        spaceID: UUID, personID: UUID, _ relationship: Relationship?
    ) async throws -> PersonSummary {
        try await put(
            "v1/spaces/\(spaceID)/people/\(personID)/relation",
            body: PersonRelationRequest(relation: relationship)
        )
    }

    /// "This is me", or not. Saying it of someone moves it to them.
    public func setIsMe(spaceID: UUID, personID: UUID, _ isMe: Bool) async throws -> PersonSummary {
        try await put("v1/spaces/\(spaceID)/people/\(personID)/me", body: PersonIsMeRequest(isMe: isMe))
    }

    // MARK: The people in one photo

    /// Who the NAS found in one photo or video. Nil where there's no People:
    /// anyone else's library, People off, or a server from before.
    public func photoPeople(spaceID: UUID, assetID: UUID) async throws -> PhotoPeopleResponse? {
        do {
            return try await get("v1/spaces/\(spaceID)/assets/\(assetID)/people")
        } catch FrameStationClientError.http(status: 404, reason: _) {
            return nil
        }
    }

    /// Says who a face is: someone in People, someone new by name, or
    /// nobody (`AssignFaceRequest()`). Answers with who's in the photo now.
    public func assignFace(
        spaceID: UUID, assetID: UUID, ordinal: Int, _ request: AssignFaceRequest
    ) async throws -> PhotoPeopleResponse {
        try await put("v1/spaces/\(spaceID)/assets/\(assetID)/faces/\(ordinal)/person", body: request)
    }

    // MARK: Faces

    /// The face that stands for someone. `face` is only there to change the
    /// URL when the face does; the NAS picks it.
    public func personFaceURL(spaceID: UUID, person: PersonSummary) -> URL? {
        URL(
            string: "v1/spaces/\(spaceID)/people/\(person.id)/face?f=\(person.face)",
            relativeTo: baseURL
        )
    }

    /// One face in one photo, for "Is this Emma?".
    public func assetFaceURL(spaceID: UUID, assetID: UUID, ordinal: Int) -> URL? {
        URL(string: "v1/spaces/\(spaceID)/assets/\(assetID)/faces/\(ordinal)", relativeTo: baseURL)
    }
}
