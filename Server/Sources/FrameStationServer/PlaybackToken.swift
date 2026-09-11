import Crypto
import Foundation
import FrameStationAPI
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

    /// The signed message. One definition, used by both sides — `verify` used to
    /// rebuild this string by hand, which is two places to keep in step and one
    /// place for them to drift apart.
    ///
    /// Quality is inside it so the link cannot be edited into a different
    /// representation: without that, a `mobile` URL could be turned into an
    /// `original` one by changing a query parameter, which is the whole point of
    /// signing.
    private static func message(
        assetID: UUID, userID: UUID, expires: Int, quality: PlaybackQuality
    ) -> Data {
        Data("\(assetID.uuidString):\(userID.uuidString):\(expires):\(quality.rawValue)".utf8)
    }

    static func sign(
        assetID: UUID, userID: UUID, expires: Int,
        quality: PlaybackQuality = .default, key: SymmetricKey
    ) -> String {
        // The user is inside the signature so a leaked link can't outlive that
        // person's access to the space any more than it already does.
        let mac = HMAC<SHA256>.authenticationCode(
            for: message(assetID: assetID, userID: userID, expires: expires, quality: quality),
            using: key
        )
        return Data(mac).base64URLEncodedString()
    }

    static func verify(
        assetID: UUID, userID: UUID, expires: Int,
        quality: PlaybackQuality = .default, signature: String, key: SymmetricKey
    ) -> Bool {
        guard expires > Int(Date().timeIntervalSince1970) else { return false }
        let expected = sign(
            assetID: assetID, userID: userID, expires: expires, quality: quality, key: key
        )
        // Constant-time: a byte-by-byte early exit would leak the signature.
        guard expected.utf8.count == signature.utf8.count else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Data(base64URLEncoded: signature) ?? Data(),
            authenticating: message(
                assetID: assetID, userID: userID, expires: expires, quality: quality
            ),
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
