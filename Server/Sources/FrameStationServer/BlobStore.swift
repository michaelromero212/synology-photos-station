import Crypto
import Foundation
import Vapor

/// Content-addressed storage on the NAS filesystem.
///
/// Layout (ARCHITECTURE.md §4):
/// ```
/// /data/blobs/ab/cd/abcd….heic          SHA-256 named
/// /data/derivatives/ab/cd/abcd…/        thumbnails, preview, poster
/// /data/incoming/<uploadID>/<n>.part     chunk staging
/// ```
///
/// The copies people browse in File Station live in their DSM homes and are
/// kept there by `BrowseTreeWorker`. The `browse/` tree that used to sit here
/// is retired by `LegacyBrowseTree`.
///
/// Originals are stored byte-for-byte. Nothing here ever rewrites an original —
/// re-encoding destroys HDR gain maps, ProRAW, depth data, and Live Photo
/// pairing.
struct BlobStore: Sendable {
    let root: URL

    private var fm: FileManager { .default }

    init(root: String) {
        self.root = URL(fileURLWithPath: root, isDirectory: true)
    }

    // MARK: - Paths

    /// Two levels of 256-way sharding keeps directory sizes sane: ~100k assets
    /// spread over 65,536 buckets is a couple of files each.
    func blobPath(sha256: String, fileExtension: String) -> URL {
        let shardA = String(sha256.prefix(2))
        let shardB = String(sha256.dropFirst(2).prefix(2))
        let name = fileExtension.isEmpty ? sha256 : "\(sha256).\(fileExtension)"
        return root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(shardA, isDirectory: true)
            .appendingPathComponent(shardB, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// `derivatives/ab/cd/<sha256>/` — thumbnails, preview, poster, HLS.
    /// Sharded the same way as blobs so the two trees stay navigable together.
    func derivativeDirectory(sha256: String) -> URL {
        root
            .appendingPathComponent("derivatives", isDirectory: true)
            .appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(sha256.dropFirst(2).prefix(2)), isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: true)
    }

    func derivativePath(sha256: String, name: String) -> URL {
        derivativeDirectory(sha256: sha256).appendingPathComponent(name)
    }

    func stagingDirectory(uploadID: UUID) -> URL {
        root
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent(uploadID.uuidString, isDirectory: true)
    }

    func chunkPath(uploadID: UUID, index: Int) -> URL {
        stagingDirectory(uploadID: uploadID).appendingPathComponent("\(index).part")
    }

    // MARK: - Chunks

    func writeChunk(uploadID: UUID, index: Int, bytes: Data) throws {
        let directory = stagingDirectory(uploadID: uploadID)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic so a connection dropped mid-write can't leave a torn chunk that
        // later reassembles into a hash mismatch.
        try bytes.write(to: chunkPath(uploadID: uploadID, index: index), options: .atomic)
    }

    func discardStaging(uploadID: UUID) {
        try? fm.removeItem(at: stagingDirectory(uploadID: uploadID))
    }

    // MARK: - Commit

    /// Reassembles chunks, verifies the hash, and moves the result into `blobs/`.
    ///
    /// Throws `BlobStoreError.hashMismatch` if the reassembled bytes don't match
    /// what the client claimed — the staged data is discarded in that case, so a
    /// corrupted transfer can never become a stored asset.
    @discardableResult
    func assemble(
        uploadID: UUID,
        chunkCount: Int,
        expectedSHA256: String,
        fileExtension: String
    ) throws -> URL {
        let destination = blobPath(sha256: expectedSHA256, fileExtension: fileExtension)

        // Another upload of the same content won the race; nothing to do.
        if fm.fileExists(atPath: destination.path) {
            discardStaging(uploadID: uploadID)
            return destination
        }

        let assembled = stagingDirectory(uploadID: uploadID)
            .appendingPathComponent("assembled.tmp")
        try? fm.removeItem(at: assembled)
        guard fm.createFile(atPath: assembled.path, contents: nil) else {
            throw BlobStoreError.cannotCreate(assembled.path)
        }

        let handle = try FileHandle(forWritingTo: assembled)
        var hasher = SHA256()

        do {
            for index in 0..<chunkCount {
                let chunk = chunkPath(uploadID: uploadID, index: index)
                guard fm.fileExists(atPath: chunk.path) else {
                    throw BlobStoreError.missingChunk(index)
                }
                // Chunks are bounded (16 MB) so a whole-chunk read is fine and
                // avoids a second streaming layer.
                let data = try Data(contentsOf: chunk, options: .mappedIfSafe)
                hasher.update(data: data)
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            discardStaging(uploadID: uploadID)
            throw error
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256.lowercased() else {
            discardStaging(uploadID: uploadID)
            throw BlobStoreError.hashMismatch(expected: expectedSHA256, actual: digest)
        }

        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: assembled, to: destination)
        discardStaging(uploadID: uploadID)

        return destination
    }

    func blobExists(sha256: String, fileExtension: String) -> Bool {
        fm.fileExists(atPath: blobPath(sha256: sha256, fileExtension: fileExtension).path)
    }

    static func fileExtension(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        // Guard against a hostile or malformed filename becoming a path segment.
        guard ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return ext
    }
}

enum BlobStoreError: Error, CustomStringConvertible {
    case cannotCreate(String)
    case missingChunk(Int)
    case hashMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .cannotCreate(let path):
            return "Could not create \(path)."
        case .missingChunk(let index):
            return "Chunk \(index) was never received."
        case .hashMismatch(let expected, let actual):
            return "Hash mismatch: client claimed \(expected), assembled bytes are \(actual)."
        }
    }
}

private struct BlobStoreKey: StorageKey {
    typealias Value = BlobStore
}

extension Application {
    var blobStore: BlobStore {
        get {
            guard let store = storage[BlobStoreKey.self] else {
                fatalError("Blob store accessed before configure(_:) ran.")
            }
            return store
        }
        set { storage[BlobStoreKey.self] = newValue }
    }
}

extension Request {
    var blobStore: BlobStore { application.blobStore }
}
