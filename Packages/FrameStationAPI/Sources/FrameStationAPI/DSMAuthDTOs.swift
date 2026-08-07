import Foundation

/// Sign-in with a DSM account. See ARCHITECTURE.md §2 — the password is sent
/// once, validated server-side against DSM on the host loopback, and never
/// stored. What comes back and gets kept is a FrameStation device token.
public struct DSMLoginRequest: Codable, Sendable {
    public let username: String
    public let password: String
    public let deviceName: String
    public let platform: Platform
    /// Six digits from an authenticator app, when the account asks for them.
    /// Optional because most accounts don't, and a code field on every sign-in
    /// is a question most people can't answer.
    public let otpCode: String?

    public init(
        username: String, password: String, deviceName: String,
        platform: Platform, otpCode: String? = nil
    ) {
        self.username = username
        self.password = password
        self.deviceName = deviceName
        self.platform = platform
        self.otpCode = otpCode
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
