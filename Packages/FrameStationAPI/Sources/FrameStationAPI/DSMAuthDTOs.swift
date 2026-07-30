import Foundation

/// Sign-in with a DSM account. See ARCHITECTURE.md §2 — the password is sent
/// once, validated server-side against DSM on the host loopback, and never
/// stored. What comes back and gets kept is a FrameStation device token.
public struct DSMLoginRequest: Codable, Sendable {
    public let username: String
    public let password: String
    public let deviceName: String
    public let platform: Platform

    public init(username: String, password: String, deviceName: String, platform: Platform) {
        self.username = username
        self.password = password
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct DSMLoginResponse: Codable, Sendable, Hashable {
    /// Shown exactly once. Persist to the Keychain immediately.
    public let token: String
    public let user: UserDTO
    public let deviceID: UUID
    public let spaces: [SpaceDTO]
    /// True the first time this DSM account signed in, so the app can offer to
    /// start a first backup rather than showing an empty library.
    public let isNewAccount: Bool

    public init(
        token: String, user: UserDTO, deviceID: UUID,
        spaces: [SpaceDTO], isNewAccount: Bool
    ) {
        self.token = token
        self.user = user
        self.deviceID = deviceID
        self.spaces = spaces
        self.isNewAccount = isNewAccount
    }
}
