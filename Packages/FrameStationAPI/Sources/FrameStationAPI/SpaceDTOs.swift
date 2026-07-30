import Foundation

// Space management. See ARCHITECTURE.md §5 — every user gets exactly one
// `personal` space at signup; "Family Shared" is just a `shared` space, which is
// why additional ones (Trip 2026, Kids) cost nothing structurally.

public struct CreateSpaceRequest: Codable, Sendable {
    public let name: String
    /// User ids to add as contributors alongside the creator, who becomes owner.
    public let memberIDs: [UUID]

    public init(name: String, memberIDs: [UUID] = []) {
        self.name = name
        self.memberIDs = memberIDs
    }
}

public struct RenameSpaceRequest: Codable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct SpaceMemberDTO: Codable, Sendable, Hashable, Identifiable {
    public let user: UserDTO
    public let role: SpaceRole
    public let joinedAt: Date
    /// How many items in this space this person put there — the attribution
    /// question at space level rather than per photo.
    public let contributedCount: Int

    public var id: UUID { user.id }

    public init(user: UserDTO, role: SpaceRole, joinedAt: Date, contributedCount: Int) {
        self.user = user
        self.role = role
        self.joinedAt = joinedAt
        self.contributedCount = contributedCount
    }
}

public struct SpaceMembersResponse: Codable, Sendable, Hashable {
    public let spaceID: UUID
    public let name: String
    public let kind: SpaceKind
    /// Whether the caller may add or remove members.
    public let callerIsOwner: Bool
    public let members: [SpaceMemberDTO]

    public init(
        spaceID: UUID, name: String, kind: SpaceKind,
        callerIsOwner: Bool, members: [SpaceMemberDTO]
    ) {
        self.spaceID = spaceID
        self.name = name
        self.kind = kind
        self.callerIsOwner = callerIsOwner
        self.members = members
    }
}

/// Everyone with an account on this NAS.
///
/// A household directory is deliberate: at family scale, adding someone to a
/// shared space should be picking them from a list, not sending a per-space
/// invitation. Personal spaces remain private regardless of who can see the
/// directory.
public struct HouseholdResponse: Codable, Sendable, Hashable {
    public let users: [UserDTO]

    public init(users: [UserDTO]) {
        self.users = users
    }
}

public struct AddMemberRequest: Codable, Sendable {
    public let role: SpaceRole

    public init(role: SpaceRole = .contributor) {
        self.role = role
    }
}
