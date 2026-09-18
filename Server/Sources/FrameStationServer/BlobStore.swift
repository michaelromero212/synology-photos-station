import Crypto
import Foundation
import Vapor

/// Content-addressed storage on the NAS filesystem.
///
/// Layout (ARCHITECTURE.md §4):
/// ```
/// /data/blobs/ab/cd/abcd….heic          canonical, SHA-256 named
/// /data/incoming/<uploadID>/<n>.part     chunk staging
/// /data/browse/<user>/2026/07/IMG_1.heic hardlinks, zero extra space
/// ```
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

    // MARK: - Browsable tree

    /// Mirrors a blob into `browse/<user>/<yyyy>/<MM>/<filename>` as a hardlink.
    ///
    /// Same inode, so this costs zero additional space, and it keeps the library
    /// inspectable from File Station and Finder — which matters a lot to NAS
    /// owners. Entirely rebuildable from the database; safe to delete.
    /// Best-effort: a failure here must never fail an upload.
    func linkIntoBrowseTree(
        blob: URL,
        userSlug: String,
        capturedAt: Date?,
        filename: String,
        logger: Logger
    ) {
        let date = capturedAt ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return }

        let directory = root
            .appendingPathComponent("browse", isDirectory: true)
            .appendingPathComponent(userSlug, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var target = directory.appendingPathComponent(filename)

            // Same content already linked here — nothing to do.
            if fm.fileExists(atPath: target.path) {
                let existing = Self.inode(of: target, using: fm)
                let incoming = Self.inode(of: blob, using: fm)
                if let existing, existing == incoming { return }

                let base = target.deletingPathExtension().lastPathComponent
                let ext = target.pathExtension
                var suffix = 2
                repeat {
                    let candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                    target = directory.appendingPathComponent(candidate)
                    suffix += 1
                } while fm.fileExists(atPath: target.path) && suffix < 100
            }

            try fm.linkItem(at: blob, to: target)
        } catch {
            logger.warning("browse tree link failed for \(filename): \(error)")
        }
    }

    /// Inode number, read defensively.
    ///
    /// `attributesOfItem` returns `[FileAttributeKey: Any]`, and the numeric
    /// values arrive as `NSNumber` on Darwin but not always with the same
    /// bridging behavior under swift-corelibs-foundation. Casting straight to
    /// `Int` works on macOS and can silently return nil on Linux — which here
    /// would mean every hardlink comparison failing and the browse tree
    /// accumulating `-2`, `-3` duplicates of files it already had.
    private static func inode(of url: URL, using fm: FileManager) -> UInt64? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let raw = attributes[.systemFileNumber] else { return nil }
        if let number = raw as? NSNumber { return number.uint64Value }
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int { return UInt64(value) }
        return nil
    }

    /// Filesystem-safe directory name for a display name.
    static func slug(_ displayName: String) -> String {
        let allowed = displayName.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "user" : collapsed.lowercased()
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
