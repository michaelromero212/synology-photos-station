import Foundation
import Security

/// Keychain-backed storage for the server URL and device token.
///
/// The token is a long-lived bearer credential the server only ever transmits
/// once — it stores a SHA-256 hash — so losing it means re-redeeming an invite,
/// and leaking it means full access to the family library. That rules out
/// UserDefaults, which is plaintext and lands in device backups.
public struct CredentialStore: Sendable {
    public struct Credentials: Sendable, Equatable {
        public let serverURL: URL
        public let token: String

        public init(serverURL: URL, token: String) {
            self.serverURL = serverURL
            self.token = token
        }
    }

    private let service: String

    public init(service: String = "com.michaelromero.FrameStation") {
        self.service = service
    }

    private var account: String { "device-credentials" }

    public func save(_ credentials: Credentials) throws {
        let payload = try JSONEncoder().encode(
            Stored(serverURL: credentials.serverURL.absoluteString, token: credentials.token)
        )

        var query = baseQuery()
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = payload
        // Not synchronised to iCloud and unavailable until first unlock: a
        // device token should not follow the user to a new device silently.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
    }

    public func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let url = URL(string: stored.serverURL)
        else { return nil }

        return Credentials(serverURL: url, token: stored.token)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct Stored: Codable {
        let serverURL: String
        let token: String
    }
}

public enum CredentialStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}
