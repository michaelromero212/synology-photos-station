import Foundation

/// Wire types shared by the server and the Apple clients.
///
/// This target deliberately depends on nothing but Foundation — the apps import
/// it too, and it must build for iOS, tvOS, and macOS. Vapor's `Content`
/// conformances are added server-side in an extension.

// MARK: - Enums

public enum Platform: String, Codable, Sendable, CaseIterable {
    case ios, ipados, macos, tvos
}

public enum SpaceKind: String, Codable, Sendable {
    case personal, shared
}

public enum SpaceRole: String, Codable, Sendable {
    case owner, contributor, viewer
}

public enum APNSEnvironment: String, Codable, Sendable {
    case sandbox, production
}

// MARK: - Core

public struct UserDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct SpaceDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let kind: SpaceKind
    public let name: String
    public let role: SpaceRole
    public let memberCount: Int

    public init(id: UUID, kind: SpaceKind, name: String, role: SpaceRole, memberCount: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.role = role
        self.memberCount = memberCount
    }

    /// Whether `user` may remove from this space a photo `addedBy` someone.
    /// See `SpacePermissions.mayRemove`.
    public func allowsRemoving(addedBy: UUID?, by user: UUID?) -> Bool {
        SpacePermissions.mayRemove(kind: kind, role: role, addedBy: addedBy, user: user)
    }
}

/// Who may do what in a space, decided once for the server and every app.
public enum SpacePermissions {
    /// Whether `user` may remove a photo or video that `addedBy` put in a space.
    ///
    /// In a shared space, what somebody added is theirs to remove, and the
    /// person who made the space may remove anything, to clear a duplicate or
    /// a mistake — the way shared albums work in Photos. Anyone who could add
    /// used to be able to remove anything, so one slip in a family album could
    /// take somebody else's photographs with it. In a personal library the one
    /// member is its owner, and may remove anything in it. Viewers remove
    /// nothing.
    ///
    /// `addedBy` is who the photo counts as added by: the credited person if
    /// there is one, otherwise whoever uploaded it, the same person "Added by"
    /// shows.
    public static func mayRemove(
        kind: SpaceKind, role: SpaceRole, addedBy: UUID?, user: UUID?
    ) -> Bool {
        switch role {
        case .viewer:
            return false
        case .owner:
            return true
        case .contributor:
            return kind == .personal || (user != nil && addedBy == user)
        }
    }

    /// Whether `user` may change who a photo is credited to.
    ///
    /// The same rule as removing, because the credit is what that rule reads:
    /// with anyone able to change it, a member could credit somebody else's
    /// photograph to themselves and then remove it. So the album's owner may
    /// credit anything, and otherwise only the person it counts as added by
    /// may hand it to someone else.
    public static func mayChangeCredit(
        kind: SpaceKind, role: SpaceRole, addedBy: UUID?, user: UUID?
    ) -> Bool {
        mayRemove(kind: kind, role: role, addedBy: addedBy, user: user)
    }

    /// Why a removal was refused, in the words both the server and the apps use.
    public static let removalRefusal =
        "Only the person who added this, or the shared library's owner, can remove it."
}

// MARK: - Auth

public struct RedeemInviteRequest: Codable, Sendable {
    public let code: String
    public let displayName: String
    public let deviceName: String
    public let platform: Platform

    public init(code: String, displayName: String, deviceName: String, platform: Platform) {
        self.code = code
        self.displayName = displayName
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct RedeemInviteResponse: Codable, Sendable, Hashable {
    /// Opaque bearer token. The server stores only its SHA-256 hash, so this is
    /// the one and only time it is transmitted — the client must persist it to
    /// the Keychain immediately.
    public let token: String
    public let user: UserDTO
    public let deviceID: UUID
    public let personalSpace: SpaceDTO

    public init(token: String, user: UserDTO, deviceID: UUID, personalSpace: SpaceDTO) {
        self.token = token
        self.user = user
        self.deviceID = deviceID
        self.personalSpace = personalSpace
    }
}

public struct MeResponse: Codable, Sendable, Hashable {
    public let user: UserDTO
    public let deviceID: UUID
    public let spaces: [SpaceDTO]

    public init(user: UserDTO, deviceID: UUID, spaces: [SpaceDTO]) {
        self.user = user
        self.deviceID = deviceID
        self.spaces = spaces
    }
}

public struct RegisterPushTokenRequest: Codable, Sendable {
    public let apnsToken: String
    public let environment: APNSEnvironment

    public init(apnsToken: String, environment: APNSEnvironment) {
        self.apnsToken = apnsToken
        self.environment = environment
    }
}

/// How much of this device's backup is still waiting.
///
/// The only reason the server is told is so it can wake the device back up —
/// see the nudger. Nothing else reads it, and a device that never reports is a
/// device that is simply never nudged.
///
/// Reported rather than inferred because it cannot be inferred: the queue lives
/// on the phone, and from the server's side a phone with four thousand photos
/// left to send and a phone that finished an hour ago look exactly alike.
public struct ReportBackupStateRequest: Codable, Sendable {
    /// Items still to upload. Zero means finished, or turned off — either way,
    /// nothing to wake up for.
    public let pending: Int

    public init(pending: Int) {
        self.pending = pending
    }
}

// MARK: - Health

public struct HealthResponse: Codable, Sendable, Hashable {
    public let status: String
    public let version: String
    public let database: String
    public let migrationsApplied: Int
    /// The git commit the running server was built from, when the image was
    /// built by CI. `version` is a hand-bumped label and can't tell one build
    /// from another; this can. Optional so either side can be older.
    public let revision: String?
    /// What this server can do beyond what every server can, such as
    /// `BackgroundUploadRequest.capability`. Nil from a server that predates
    /// the list, which can do none of it.
    public let capabilities: [String]?

    public init(
        status: String, version: String, database: String, migrationsApplied: Int,
        revision: String? = nil, capabilities: [String]? = nil
    ) {
        self.status = status
        self.version = version
        self.database = database
        self.migrationsApplied = migrationsApplied
        self.revision = revision
        self.capabilities = capabilities
    }
}

// MARK: - Errors

public struct APIErrorResponse: Codable, Sendable, Error {
    public let error: String
    public let reason: String

    public init(error: String, reason: String) {
        self.error = error
        self.reason = reason
    }
}

/// A ready-to-play URL for a video, signed and short-lived.
///
/// Returned rather than constructed client-side so the signing scheme stays a
/// server concern and can change without shipping a new app.
/// Which representation of a video to stream.
///
/// The *client* resolves this, because the server cannot see which network the
/// phone is on. A user-facing "Auto" becomes `.original` on wi-fi and `.mobile`
/// on cellular before the request is ever made.
public enum PlaybackQuality: String, Codable, Sendable, CaseIterable {
    /// The file exactly as it was recorded. Needs a link that can carry it —
    /// roughly 51 Mbps for 4K60 — so this is the wi-fi answer.
    case original
    /// Smaller, for links that can't: a stream ladder for an app that asks for
    /// one (`adaptive=1`), otherwise the 1080p rendition an older server made.
    /// The sound is the original's; only the picture is reduced.
    case mobile

    /// What an older client gets when it asks for nothing, so a version skew
    /// keeps behaving exactly as it did before renditions existed.
    public static let `default` = PlaybackQuality.original
}

public struct PlaybackURLResponse: Codable, Sendable, Hashable {
    public let url: URL
    public let expiresAt: Date
    /// What the link plays: "direct", the stored file as it is; "rendition",
    /// the one 1080p file older servers made for cellular; or "adaptive", a
    /// stream ladder — an HLS playlist of sizes the player chooses between,
    /// handed only to an app that asked for one. A player takes any of them
    /// at the same call site.
    public let kind: String

    public init(url: URL, expiresAt: Date, kind: String = "direct") {
        self.url = url
        self.expiresAt = expiresAt
        self.kind = kind
    }
}

// MARK: - Albums

/// An album somebody made by hand: yours alone, shared with people you chose,
/// or a family album that belongs to a shared library.
public struct AlbumDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let itemCount: Int
    /// For the cover thumbnail. Nil while the album is empty.
    public let coverAssetID: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    /// The shared library a family album belongs to. Nil for an album that's
    /// yours alone, and from a server that predates family albums.
    public let spaceID: UUID?
    /// Whether you may rename or delete it: always for your own; for a family
    /// album, if you made it or own its library. Nil from an older server,
    /// where every album was your own.
    public let canManage: Bool?
    /// Whether you may add photos. False in a library you can only view.
    public let canAdd: Bool?
    /// Everyone else an album shared with people is shared with. Nil for one
    /// that isn't: yours alone, or a family album, which everyone in its
    /// library sees.
    public let people: [UserDTO]?
    /// Who made an album shared with people: you, or whoever shared it with
    /// you. Nil otherwise.
    public let owner: UserDTO?

    public init(
        id: UUID, name: String, itemCount: Int,
        coverAssetID: UUID?, createdAt: Date, updatedAt: Date,
        spaceID: UUID? = nil, canManage: Bool? = nil, canAdd: Bool? = nil,
        people: [UserDTO]? = nil, owner: UserDTO? = nil
    ) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.spaceID = spaceID
        self.canManage = canManage
        self.canAdd = canAdd
        self.people = people
        self.owner = owner
    }

    /// Seen by somebody other than you: shared with people, or in a library.
    public var isFamily: Bool { spaceID != nil }
    /// Shared with people you chose, rather than with a whole library.
    public var isSharedWithPeople: Bool { people != nil }
    /// A family album: one belonging to a shared library.
    public var isLibraryAlbum: Bool { spaceID != nil && people == nil }
    public var mayManage: Bool { canManage ?? true }
    public var mayAdd: Bool { canAdd ?? true }
}

public struct AlbumListResponse: Codable, Sendable {
    public let albums: [AlbumDTO]
    /// True when the list includes family albums, which a server only does
    /// when it has them. Nil from an older server: offer no family albums.
    public let includesFamilyAlbums: Bool?
    /// The shared libraries you're in, drawn as album cards under Shared
    /// Albums, alongside the family albums. Nil without `?shared=true`, and
    /// from an older server.
    public let libraries: [SharedLibrarySummary]?
    /// True when the list includes albums shared with people, which a server
    /// sends only when asked with `?people=true`. An app from before them
    /// would have filed them under a library it couldn't find.
    public let includesPeopleAlbums: Bool?

    public init(
        albums: [AlbumDTO], includesFamilyAlbums: Bool? = nil,
        libraries: [SharedLibrarySummary]? = nil, includesPeopleAlbums: Bool? = nil
    ) {
        self.albums = albums
        self.includesFamilyAlbums = includesFamilyAlbums
        self.libraries = libraries
        self.includesPeopleAlbums = includesPeopleAlbums
    }
}

/// A shared library as the Albums page shows it: a card like any album's,
/// with its most recently added photo for a cover.
public struct SharedLibrarySummary: Codable, Sendable, Identifiable, Hashable {
    /// The library's space id.
    public let id: UUID
    public let name: String
    public let memberCount: Int
    public let itemCount: Int
    /// Nil while the library is empty.
    public let coverAssetID: UUID?

    public init(id: UUID, name: String, memberCount: Int, itemCount: Int, coverAssetID: UUID?) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
        self.itemCount = itemCount
        self.coverAssetID = coverAssetID
    }
}

public struct CreateAlbumRequest: Codable, Sendable {
    public let name: String
    /// Optional first contents, so "select photos → new album" is one call.
    public let spaceAssetIDs: [UUID]
    /// The shared library a family album belongs to. Nil for one that's yours
    /// alone.
    public let spaceID: UUID?
    /// The people to share it with, from the household. Empty or nil, it's
    /// yours alone. Not with `spaceID`: an album is shared with a library or
    /// with people, never both. A server without `ServerCapability.peopleAlbums`
    /// ignores it.
    public let memberIDs: [UUID]?

    public init(
        name: String, spaceAssetIDs: [UUID] = [], spaceID: UUID? = nil,
        memberIDs: [UUID]? = nil
    ) {
        self.name = name
        self.spaceAssetIDs = spaceAssetIDs
        self.spaceID = spaceID
        self.memberIDs = memberIDs
    }
}

/// Who an album is shared with, replacing whoever it was. Its owner sends it.
/// Somebody added sees the album and can add to it; somebody left out loses
/// it. Nobody at all, and the album is its owner's alone again.
public struct SetAlbumPeopleRequest: Codable, Sendable {
    public let memberIDs: [UUID]

    public init(memberIDs: [UUID]) {
        self.memberIDs = memberIDs
    }
}

public struct UpdateAlbumRequest: Codable, Sendable {
    public let name: String?
    public let coverAssetID: UUID?
    public init(name: String? = nil, coverAssetID: UUID? = nil) {
        self.name = name
        self.coverAssetID = coverAssetID
    }
}

/// Placements to add — not bare asset ids, so an album can only ever contain
/// photos the owner can already see. A family album takes photos from
/// elsewhere by sharing them into its library first.
public struct AlbumAssetsRequest: Codable, Sendable {
    public let spaceAssetIDs: [UUID]
    public init(spaceAssetIDs: [UUID]) { self.spaceAssetIDs = spaceAssetIDs }
}

// MARK: - Rating and tags

/// Stars, 0–5. Zero means unrated — the server stores it as NULL, so there is
/// one representation of "no stars" rather than two that look identical.
public struct SetRatingRequest: Codable, Sendable {
    public let rating: Int
    public init(rating: Int) { self.rating = rating }
}

/// Adds and removes in one call.
///
/// Not a replace-the-whole-list PUT, because the same request has to work for a
/// selection of twelve photos that don't share a tag list. "Add Beach" means
/// add Beach to all twelve, not overwrite what each of them already had.
public struct EditTagsRequest: Codable, Sendable {
    public let add: [String]
    public let remove: [String]

    public init(add: [String] = [], remove: [String] = []) {
        self.add = add
        self.remove = remove
    }
}

/// The resulting tags — of one photo after an edit, or of a whole space.
public struct TagListResponse: Codable, Sendable, Hashable {
    public let tags: [String]
    public init(tags: [String]) { self.tags = tags }
}
