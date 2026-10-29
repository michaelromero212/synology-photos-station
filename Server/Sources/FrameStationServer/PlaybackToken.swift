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

    /// What a stream ladder's links are signed for, beside the two
    /// `PlaybackQuality` values. Never one of theirs, so a ladder's link can't
    /// be turned into one for the original.
    static let adaptive = "adaptive"

    /// How long a ladder's link lasts: long enough to watch the clip through
    /// twice with pauses, and never less than ten minutes or more than four
    /// hours.
    ///
    /// Longer than a file's link because it can't be renewed under the player.
    /// Every piece a player fetches resolves against the playlist's address,
    /// signature and all, so a fresh link means a fresh player item, and a
    /// stall to change it. Revoking someone still takes effect at once: the
    /// membership check runs on every piece, not only on the playlist.
    static func adaptiveLifetime(durationMS: Int?) -> TimeInterval {
        let seconds = Double(durationMS ?? 0) / 1000
        return min(4 * 3600, max(600, seconds * 2 + 600))
    }

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
    ///
    /// `representation` is a quality's raw value, or `adaptive` for a ladder.
    private static func message(
        assetID: UUID, userID: UUID, expires: Int, representation: String
    ) -> Data {
        Data("\(assetID.uuidString):\(userID.uuidString):\(expires):\(representation)".utf8)
    }

    static func sign(
        assetID: UUID, userID: UUID, expires: Int,
        quality: PlaybackQuality = .default, key: SymmetricKey
    ) -> String {
        sign(
            assetID: assetID, userID: userID, expires: expires,
            representation: quality.rawValue, key: key
        )
    }

    static func sign(
        assetID: UUID, userID: UUID, expires: Int, representation: String, key: SymmetricKey
    ) -> String {
        // The user is inside the signature so a leaked link can't outlive that
        // person's access to the space any more than it already does.
        let mac = HMAC<SHA256>.authenticationCode(
            for: message(
                assetID: assetID, userID: userID, expires: expires, representation: representation
            ),
            using: key
        )
        return Data(mac).base64URLEncodedString()
    }

    static func verify(
        assetID: UUID, userID: UUID, expires: Int,
        quality: PlaybackQuality = .default, signature: String, key: SymmetricKey
    ) -> Bool {
        verify(
            assetID: assetID, userID: userID, expires: expires,
            representation: quality.rawValue, signature: signature, key: key
        )
    }

    static func verify(
        assetID: UUID, userID: UUID, expires: Int, representation: String,
        signature: String, key: SymmetricKey
    ) -> Bool {
        guard expires > Int(Date().timeIntervalSince1970) else { return false }
        let expected = sign(
            assetID: assetID, userID: userID, expires: expires,
            representation: representation, key: key
        )
        // Constant-time: a byte-by-byte early exit would leak the signature.
        guard expected.utf8.count == signature.utf8.count else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Data(base64URLEncoded: signature) ?? Data(),
            authenticating: message(
                assetID: assetID, userID: userID, expires: expires, representation: representation
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
