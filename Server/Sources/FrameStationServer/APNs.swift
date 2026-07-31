import Crypto
import Foundation
import FrameStationAPI
import NIOHTTP1
import Vapor

/// Sends notifications to Apple.
///
/// Token-based (`.p8`) rather than certificate-based: one key covers every
/// bundle ID on the team and does not expire annually, which matters for a
/// household server nobody is going to babysit.
///
/// Deliberately degrades: with no key configured, `send` logs what it *would*
/// have sent and reports success. That keeps development and the smoke tests
/// working without Apple credentials, and means a misconfigured NAS drops
/// notifications instead of wedging the sweeper.
actor APNsClient {

    struct Configuration {
        var keyPEM: String
        var keyID: String
        var teamID: String
        /// The app's bundle identifier.
        var topic: String

        /// Reads `FRAMESTATION_APNS_*`. Returns nil when push isn't configured.
        static func fromEnvironment() throws -> Configuration? {
            guard let keyID = Environment.get("FRAMESTATION_APNS_KEY_ID"),
                  let teamID = Environment.get("FRAMESTATION_APNS_TEAM_ID"),
                  let topic = Environment.get("FRAMESTATION_APNS_TOPIC")
            else { return nil }

            let pem: String
            if let path = Environment.get("FRAMESTATION_APNS_KEY_PATH") {
                pem = try String(contentsOfFile: path, encoding: .utf8)
            } else if let inline = Environment.get("FRAMESTATION_APNS_KEY") {
                pem = inline
            } else {
                return nil
            }
            return Configuration(keyPEM: pem, keyID: keyID, teamID: teamID, topic: topic)
        }
    }

    struct Notification {
        var title: String
        var body: String
        var threadID: String?
        /// Merged into the payload alongside `aps`.
        var custom: [String: String] = [:]
    }

    /// What Apple said about one token.
    enum Outcome: Equatable {
        case delivered
        /// The token is dead — the app was uninstalled or the device wiped.
        /// Callers should forget it rather than retry.
        case unregistered
        case failed(String)
    }

    private let configuration: Configuration?
    private let client: any Client
    private let logger: Logger

    /// APNs requires a fresh JWT between 20 and 60 minutes; reusing one for
    /// every push is required, not just an optimisation — Apple rate-limits
    /// clients that mint a new token per request.
    private var cachedToken: (value: String, issued: Date)?

    init(configuration: Configuration?, client: any Client, logger: Logger) {
        self.configuration = configuration
        self.client = client
        self.logger = logger
    }

    var isConfigured: Bool { configuration != nil }

    func send(
        _ notification: Notification,
        to deviceToken: String,
        environment: APNSEnvironment
    ) async -> Outcome {
        guard let configuration else {
            logger.info("""
                push not configured — would have sent "\(notification.title): \
                \(notification.body)" to \(deviceToken.prefix(8))…
                """)
            return .delivered
        }

        let host = environment == .production
            ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        let url = URI(string: "https://\(host)/3/device/\(deviceToken)")

        var payload: [String: Any] = [
            "aps": [
                "alert": ["title": notification.title, "body": notification.body],
                "sound": "default",
                // Lets iOS group a space's notifications together.
                "thread-id": notification.threadID ?? notification.title,
            ] as [String: Any]
        ]
        for (key, value) in notification.custom { payload[key] = value }

        do {
            let jwt = try signedToken(configuration)
            let body = try JSONSerialization.data(withJSONObject: payload)

            let response = try await client.post(url) { request in
                request.headers.replaceOrAdd(name: "authorization", value: "bearer \(jwt)")
                request.headers.replaceOrAdd(name: "apns-topic", value: configuration.topic)
                request.headers.replaceOrAdd(name: "apns-push-type", value: "alert")
                request.headers.replaceOrAdd(name: "apns-priority", value: "10")
                request.headers.contentType = .json
                request.body = ByteBuffer(data: body)
            }

            switch response.status {
            case .ok:
                return .delivered
            case .gone:
                // 410: token no longer valid for this topic.
                return .unregistered
            default:
                let reason = response.body.map { String(buffer: $0) } ?? "no body"
                // 400 BadDeviceToken is also terminal, and is what a
                // sandbox/production mix-up looks like.
                if reason.contains("BadDeviceToken") || reason.contains("Unregistered") {
                    return .unregistered
                }
                return .failed("\(response.status.code): \(reason)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - JWT

    private func signedToken(_ configuration: Configuration) throws -> String {
        if let cached = cachedToken, Date().timeIntervalSince(cached.issued) < 45 * 60 {
            return cached.value
        }

        let issued = Date()
        let header = ["alg": "ES256", "kid": configuration.keyID]
        let claims: [String: Any] = [
            "iss": configuration.teamID, "iat": Int(issued.timeIntervalSince1970),
        ]

        let signingInput = [
            try JSONSerialization.data(withJSONObject: header, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys),
        ].map { $0.base64URLEncodedString() }.joined(separator: ".")

        let key = try P256.Signing.PrivateKey(pemRepresentation: configuration.keyPEM)
        let signature = try key.signature(for: Data(signingInput.utf8))
        // ES256 wants raw r||s, which is exactly `rawRepresentation` — the DER
        // form Apple would reject is what `derRepresentation` gives.
        let token = signingInput + "." + signature.rawRepresentation.base64URLEncodedString()

        cachedToken = (token, issued)
        return token
    }
}

extension Data {
    /// base64url, unpadded — what JWS requires.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
