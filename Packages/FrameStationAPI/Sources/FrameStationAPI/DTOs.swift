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

// MARK: - Health

public struct HealthResponse: Codable, Sendable, Hashable {
    public let status: String
    public let version: String
    public let database: String
    public let migrationsApplied: Int

    public init(status: String, version: String, database: String, migrationsApplied: Int) {
        self.status = status
        self.version = version
        self.database = database
        self.migrationsApplied = migrationsApplied
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
    /// The 1080p rendition, for links that can't. Audio is bit-identical to the
    /// original; only the picture is reduced.
    case mobile

    /// What an older client gets when it asks for nothing, so a version skew
    /// keeps behaving exactly as it did before renditions existed.
    public static let `default` = PlaybackQuality.original
}

public struct PlaybackURLResponse: Codable, Sendable, Hashable {
    public let url: URL
    public let expiresAt: Date
    /// Direct play of the stored file — no transcode. HLS would land here later
    /// as a different value without changing the call site.
    public let kind: String

    public init(url: URL, expiresAt: Date, kind: String = "direct") {
        self.url = url
        self.expiresAt = expiresAt
        self.kind = kind
    }
}

// MARK: - Albums

public struct AlbumDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let itemCount: Int
    /// For the cover thumbnail. Nil while the album is empty.
    public let coverAssetID: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, name: String, itemCount: Int,
        coverAssetID: UUID?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AlbumListResponse: Codable, Sendable {
    public let albums: [AlbumDTO]
    public init(albums: [AlbumDTO]) { self.albums = albums }
}

public struct CreateAlbumRequest: Codable, Sendable {
    public let name: String
    /// Optional first contents, so "select photos → new album" is one call.
    public let spaceAssetIDs: [UUID]

    public init(name: String, spaceAssetIDs: [UUID] = []) {
        self.name = name
        self.spaceAssetIDs = spaceAssetIDs
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
/// photos the owner can already see.
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
