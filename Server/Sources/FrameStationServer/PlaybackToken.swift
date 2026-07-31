import Crypto
import Foundation
import Vapor

/// Short-lived, single-asset URL signing for video playback.
///
/// AVPlayer fetches media itself, outside our `URLSession`, so it cannot carry
/// the bearer token the rest of the API uses. The documented alternative is an
/// `AVAssetResourceLoaderDelegate`, but a hand-written one has to reimplement
/// byte-range handling correctly — and it still wouldn't help AirPlay, where an
/// Apple TV fetches the URL on its own and never sees any header we set.
///
/// So playback URLs carry their own signature. The tradeoff, stated plainly: a
/// signed URL appears in the server's access log. It is scoped to one asset,
/// expires in minutes, and the log lives on the same NAS as the blobs it points
/// at, so this buys AirPlay and tvOS support for very little.
enum PlaybackToken {
    static let lifetime: TimeInterval = 300

    /// Stable across restarts when configured; otherwise per-boot, which only
    /// means links minted before a restart stop working a few minutes early.
    static func secret(for app: Application) -> SymmetricKey {
        if let configured = Environment.get("FRAMESTATION_STREAM_SECRET") {
            return SymmetricKey(data: Data(configured.utf8))
        }
        if let existing = app.storage[SecretKey.self] { return existing }
        let generated = SymmetricKey(size: .bits256)
        app.storage[SecretKey.self] = generated
        return generated
    }

    struct SecretKey: StorageKey { typealias Value = SymmetricKey }

    static func sign(assetID: UUID, userID: UUID, expires: Int, key: SymmetricKey) -> String {
        // The user is inside the signature so a leaked link can't outlive that
        // person's access to the space any more than it already does.
        let message = "\(assetID.uuidString):\(userID.uuidString):\(expires)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64URLEncodedString()
    }

    static func verify(
        assetID: UUID, userID: UUID, expires: Int, signature: String, key: SymmetricKey
    ) -> Bool {
        guard expires > Int(Date().timeIntervalSince1970) else { return false }
        let expected = sign(assetID: assetID, userID: userID, expires: expires, key: key)
        // Constant-time: a byte-by-byte early exit would leak the signature.
        guard expected.utf8.count == signature.utf8.count else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Data(base64URLEncoded: signature) ?? Data(),
            authenticating: Data("\(assetID.uuidString):\(userID.uuidString):\(expires)".utf8),
            using: key
        )
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        self.init(base64Encoded: padded)
    }
}
