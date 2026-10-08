import Crypto
import Foundation
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Content-addressed storage on the NAS filesystem.
///
/// Layout (ARCHITECTURE.md §4):
/// ```
/// /data/blobs/ab/cd/abcd….heic             SHA-256 named
/// /data/derivatives/ab/cd/abcd…/           thumbnails, preview, poster
/// /data/incoming/<uploadID>/upload.data    an upload in progress
/// ```
///
/// An upload that was already partway through when the server updated may
/// still be staged the old way, as `incoming/<uploadID>/<n>.part`, one file per
/// chunk. It finishes that way. See `writeChunk`.
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

    /// The file an upload's chunks are written into, each at its own offset.
    /// At commit it becomes the blob itself.
    func uploadDataPath(uploadID: UUID) -> URL {
        stagingDirectory(uploadID: uploadID).appendingPathComponent("upload.data")
    }

    /// One chunk as a file of its own: how uploads were staged before
    /// `uploadDataPath`. Only an upload that was partway through when the
    /// server updated still has these.
    func chunkPath(uploadID: UUID, index: Int) -> URL {
        stagingDirectory(uploadID: uploadID).appendingPathComponent("\(index).part")
    }

    // MARK: - Chunks

    /// Writes one chunk where it belongs in the finished file.
    ///
    /// Straight into the one file the upload will become, at the chunk's own
    /// offset, so the commit has nothing to copy. Chunks used to land as files
    /// of their own, and the commit read them all back and wrote the whole
    /// upload out a second time. On the NAS's hard drives that copy was 25.4 s
    /// of a 25.8 s commit for a 1.7 GB video, and 15 to 19 s for 1.2 to 1.3 GB
    /// ones.
    ///
    /// Chunks arrive in any order, the phone sending two at once, and each
    /// lands at its offset regardless: a chunk not yet sent is a hole until it
    /// arrives. Nothing here is trusted. The commit checks the whole file
    /// against the SHA-256 the phone sent before keeping it.
    ///
    /// A chunk only gets here whole: Vapor collects the body before the
    /// handler runs, and `uploadChunk` checks its size first. A crash mid-write
    /// leaves the chunk unrecorded, so it's sent again, and anything torn that
    /// slips past is a hash mismatch at commit.
    func writeChunk(uploadID: UUID, index: Int, chunkSize: Int, bytes: Data) throws {
        let directory = stagingDirectory(uploadID: uploadID)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // An upload that started before this server finishes the way it
        // started, one file per chunk.
        if hasChunkFiles(uploadID: uploadID) {
            try bytes.write(to: chunkPath(uploadID: uploadID, index: index), options: .atomic)
            return
        }

        // Created if missing and never truncated: two chunks can arrive at
        // once, and either may be the first. 0o666 is what Foundation's
        // `createFile` asks for, so the blob ends up with the same permissions
        // an assembled one had.
        let path = uploadDataPath(uploadID: uploadID).path
        let descriptor = open(path, O_WRONLY | O_CREAT, 0o666)
        guard descriptor >= 0 else { throw BlobStoreError.cannotCreate(path) }
        defer { close(descriptor) }

        let offset = off_t(index) * off_t(chunkSize)
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = pwrite(
                    descriptor, base + written, buffer.count - written,
                    offset + off_t(written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw BlobStoreError.cannotWrite(path, errno)
                }
                written += result
            }
        }
    }

    /// Whether this upload was staged the old way, one file per chunk.
    private func hasChunkFiles(uploadID: UUID) -> Bool {
        let names = (try? fm.contentsOfDirectory(
            atPath: stagingDirectory(uploadID: uploadID).path
        )) ?? []
        return names.contains { $0.hasSuffix(".part") }
    }

    func discardStaging(uploadID: UUID) {
        try? fm.removeItem(at: stagingDirectory(uploadID: uploadID))
    }

    // MARK: - Commit

    /// Verifies the upload's hash and moves it into `blobs/`.
    ///
    /// Throws `BlobStoreError.hashMismatch` if the bytes don't match what the
    /// client claimed — the staged data is discarded in that case, so a
    /// corrupted transfer can never become a stored asset.
    ///
    /// One read and a rename. The chunks are already in place in one file (see
    /// `writeChunk`), so this reads it once to check it and moves it into
    /// `blobs/`, which is the same volume, so nothing is copied.
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

        let staged = uploadDataPath(uploadID: uploadID)
        guard fm.fileExists(atPath: staged.path) else {
            // Staged the old way, one file per chunk.
            return try assembleChunkFiles(
                uploadID: uploadID, chunkCount: chunkCount,
                expectedSHA256: expectedSHA256, destination: destination
            )
        }

        let digest: String
        do {
            digest = try Self.sha256(of: staged)
        } catch {
            discardStaging(uploadID: uploadID)
            throw error
        }
        // The hash covers the length too: a missing tail or a stray byte past
        // the end hashes differently from what the phone sent.
        guard digest == expectedSHA256.lowercased() else {
            discardStaging(uploadID: uploadID)
            throw BlobStoreError.hashMismatch(expected: expectedSHA256, actual: digest)
        }

        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: staged, to: destination)
        discardStaging(uploadID: uploadID)
        return destination
    }

    /// Streams a file through SHA-256.
    ///
    /// Each read is drained on Darwin, where the dev server runs: `FileHandle`
    /// returns reads autoreleased, and without the drain a loop like this held
    /// the whole file in memory in the app (see `FileUpload.hashFile`). Linux
    /// has no autorelease pools.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try drained({
            guard let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty
            else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func drained<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }

    /// Commits an upload staged before `upload.data`: reads every chunk file,
    /// hashes it, and writes the whole upload out again as one file.
    private func assembleChunkFiles(
        uploadID: UUID,
        chunkCount: Int,
        expectedSHA256: String,
        destination: URL
    ) throws -> URL {
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

    /// Keeps a file that arrived whole, already hashed as it came in: a
    /// background upload, which has no chunks to check. Moved into `blobs/`,
    /// the same volume, so nothing is copied. If the same bytes are already
    /// stored, the copy that just arrived is dropped and the stored one kept.
    @discardableResult
    func keepStaged(uploadID: UUID, sha256: String, fileExtension: String) throws -> URL {
        let destination = blobPath(sha256: sha256, fileExtension: fileExtension)
        if fm.fileExists(atPath: destination.path) {
            discardStaging(uploadID: uploadID)
            return destination
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.moveItem(at: uploadDataPath(uploadID: uploadID), to: destination)
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
    case cannotWrite(String, Int32)
    case missingChunk(Int)
    case hashMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .cannotCreate(let path):
            return "Could not create \(path)."
        case .cannotWrite(let path, let code):
            return "Could not write \(path): \(String(cString: strerror(code)))."
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
