import Crypto
import Foundation

/// Seals face embeddings before they're stored. They're biometric data: see
/// NAS-ANALYSIS.md §6.
///
/// AES-GCM under one key per install, kept in `secrets/` next to the push key
/// and readable only by root on the NAS. Each embedding is bound to its own
/// row (person, file, ordinal) as authenticated data, so a sealed value copied
/// onto another row fails to open rather than becoming someone else's face.
///
/// What this protects against is a copy of the data: a database dump, a
/// backup of `pgdata`, the `docker` share's world-readable files. It doesn't
/// protect against the running server, which holds the key and every
/// photograph anyway. Losing the key loses nothing that can't be made again;
/// the analyzer simply runs once more.
struct FaceSeal: Sendable {
    static let keyFileName = "face-embeddings.key"

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The install's key, made on first use with 0600 permissions in a 0700
    /// directory.
    static func load(secretsDirectory: String) throws -> FaceSeal {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: secretsDirectory, isDirectory: true)
        let path = directory.appendingPathComponent(keyFileName).path
        if fm.fileExists(atPath: path) {
            // There, but unreadable, is a problem to report, never a reason to
            // write a new key over the one the stored faces were sealed with.
            guard let data = fm.contents(atPath: path) else { throw SealError.unreadableKey }
            guard data.count == 32 else { throw SealError.badKey }
            return FaceSeal(key: SymmetricKey(data: data))
        }
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        guard fm.createFile(atPath: path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw SealError.cannotWriteKey
        }
        return FaceSeal(key: key)
    }

    /// The key that's there, without ever making one: for checking what's
    /// stored, where a new key would only make every face look broken.
    static func existing(secretsDirectory: String) throws -> FaceSeal {
        let path = URL(fileURLWithPath: secretsDirectory, isDirectory: true)
            .appendingPathComponent(keyFileName).path
        guard let data = FileManager.default.contents(atPath: path) else { throw SealError.noKey }
        guard data.count == 32 else { throw SealError.badKey }
        return FaceSeal(key: SymmetricKey(data: data))
    }

    func seal(_ embedding: Data, userID: UUID, sha256: String, ordinal: Int) throws -> Data {
        let box = try AES.GCM.seal(embedding, using: key, authenticating: Self.context(userID, sha256, ordinal))
        guard let combined = box.combined else { throw SealError.sealFailed }
        return combined
    }

    func open(_ sealed: Data, userID: UUID, sha256: String, ordinal: Int) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key, authenticating: Self.context(userID, sha256, ordinal))
    }

    private static func context(_ userID: UUID, _ sha256: String, _ ordinal: Int) -> Data {
        Data("framestation-face|\(userID.uuidString.lowercased())|\(sha256)|\(ordinal)".utf8)
    }

    enum SealError: Error, CustomStringConvertible {
        case noKey, unreadableKey, badKey, cannotWriteKey, sealFailed

        var description: String {
            switch self {
            case .noKey: return "there is no face key in secrets/"
            case .unreadableKey: return "the face key in secrets/ can't be read"
            case .badKey: return "the face key in secrets/ isn't 32 bytes"
            case .cannotWriteKey: return "the face key couldn't be written to secrets/"
            case .sealFailed: return "sealing failed"
            }
        }
    }
}
