import Crypto
import Dispatch
import Foundation
import SQLKit
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Retires the M1a browse tree: `<blob root>/browse/<name>/YYYY/MM/…`.
///
/// Every upload used to hardlink its blob into that tree — a view of the
/// library for File Station from before photos lived in each person's home.
/// The home tree replaced it (see `BrowseTreeWorker`) and nothing reads the old
/// one, but commits went on adding to it, and nothing ever took anything out.
/// A hardlink is a second name for the same bytes, so when the retention
/// sweeper — or Delete Permanently — unlinked a blob, the bytes stayed on disk
/// under the old tree's name: a permanently deleted photograph, still taking up
/// space and still readable by anyone who could open that folder.
///
/// This takes the tree apart without losing anything a photo still needs:
///
/// - A file with another name (link count ≥ 2) is only an extra name, and the
///   blob keeps the bytes. The name goes.
/// - A file that is the *only* name for its bytes is identified by hashing it:
///   - still wanted by a live or recoverable photo whose blob has gone missing —
///     it is that photo's last copy, so it is moved back into the blob store;
///   - wanted, and the blob is there — a duplicate, removed;
///   - known, but every placement of it has been purged — the photograph its
///     owner permanently deleted, removed at last;
///   - unknown to the database — left exactly where it is, and reported. Not
///     understanding a file is never a reason to delete it.
///
/// Runs by itself once at startup and is a no-op after the tree is gone;
/// `FrameStationServer retire-legacy-browse --dry-run` shows what it would do.
enum LegacyBrowseTree {
    struct Report: Sendable {
        var extraNames = 0
        var permanentlyDeleted = 0
        var duplicates = 0
        var freedBytes: Int64 = 0
        var restored = 0
        var unrecognized: [String] = []
        var failures = 0

        var isEmpty: Bool {
            extraNames == 0 && permanentlyDeleted == 0 && duplicates == 0
                && restored == 0 && unrecognized.isEmpty && failures == 0
        }

        var summary: String {
            var parts = ["removed \(extraNames) extra name(s)"]
            parts.append(
                "freed \(Self.describe(freedBytes)) from \(permanentlyDeleted) permanently "
                    + "deleted photo(s) and \(duplicates) duplicate(s)"
            )
            parts.append("restored \(restored) missing blob(s)")
            parts.append("left \(unrecognized.count) unrecognized file(s) in place")
            if failures > 0 { parts.append("\(failures) failure(s), see above") }
            return parts.joined(separator: ", ")
        }

        static func describe(_ bytes: Int64) -> String {
            let value = Double(bytes)
            if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
            if value >= 1e6 { return String(format: "%.1f MB", value / 1e6) }
            return "\(bytes) bytes"
        }
    }

    /// The tree's root under the blob store.
    static func root(of store: BlobStore) -> URL {
        store.root.appendingPathComponent("browse", isDirectory: true)
    }

    /// Takes the tree apart, or with `dryRun` only says what that would do.
    static func retire(
        store: BlobStore, sql: any SQLDatabase, logger: Logger, dryRun: Bool
    ) async throws -> Report? {
        let root = Self.root(of: store).path
        guard FileManager.default.fileExists(atPath: root) else { return nil }

        // The walk is all blocking filesystem calls, tens of thousands of them
        // on a large library — kept off the handful of threads every request
        // shares, the same reason chunk writes are.
        let walked = try await offPool { Self.walk(root: root, dryRun: dryRun) }
        var report = walked.0
        let soleNames = walked.1

        // The files that are the only name for their bytes. Few — one per
        // purged photo — so each is hashed and looked up on its own.
        for file in soleNames {
            do {
                let sha = try await offPool { try Self.sha256(ofFile: file.path) }
                try await settle(
                    file, sha256: sha, store: store, sql: sql, dryRun: dryRun,
                    logger: logger, report: &report
                )
            } catch {
                report.failures += 1
                logger.error("legacy browse tree: could not settle \(file.path): \(error)")
            }
        }

        if !dryRun {
            try await offPool { Self.removeEmptyDirectories(under: root) }
        }
        return report
    }

    /// Runs `retire` in the background at startup and logs what it did.
    static func retireInBackground(app: Application) async {
        do {
            guard let report = try await retire(
                store: app.blobStore, sql: app.sql, logger: app.logger, dryRun: false
            ) else { return }
            app.logger.notice("legacy browse tree: \(report.summary)")
            for path in report.unrecognized.prefix(20) {
                app.logger.notice("legacy browse tree: left unrecognized \(path)")
            }
        } catch {
            app.logger.error("legacy browse tree: \(String(reflecting: error))")
        }
    }

    // MARK: - Walking

    struct SoleName: Sendable {
        let path: String
        let size: Int64
    }

    /// Removes every extra name and DSM's own clutter, and returns the files
    /// that are the only name for their bytes.
    private static func walk(root: String, dryRun: Bool) -> (Report, [SoleName]) {
        var report = Report()
        var soleNames: [SoleName] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else { return (report, soleNames) }

        while let relative = walker.nextObject() as? String {
            let path = (root as NSString).appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent

            // DSM indexes shared folders into `@eaDir` beside each file, and a
            // Mac browsing over SMB leaves `.DS_Store`. Neither is a photo.
            if name == "@eaDir" {
                walker.skipDescendants()
                if !dryRun { try? fm.removeItem(atPath: path) }
                continue
            }
            if name == ".DS_Store" || name == "Thumbs.db" {
                if !dryRun { try? fm.removeItem(atPath: path) }
                continue
            }

            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { continue }

            if Int(info.st_nlink) >= 2 {
                // Another name — the blob — still holds these bytes.
                if !dryRun {
                    guard unlink(path) == 0 else {
                        report.failures += 1
                        continue
                    }
                }
                report.extraNames += 1
            } else {
                soleNames.append(SoleName(path: path, size: Int64(info.st_size)))
            }
        }
        return (report, soleNames)
    }

    private struct Wanted: Decodable {
        /// A blob extension of a live or recoverable asset over these bytes.
        let wantedExt: String?
        /// Whether any asset over these bytes has ever been placed anywhere.
        let known: Bool
    }

    private static func settle(
        _ file: SoleName, sha256: String, store: BlobStore, sql: any SQLDatabase,
        dryRun: Bool, logger: Logger, report: inout Report
    ) async throws {
        let wanted = try await sql.raw("""
            SELECT
                (SELECT a.blob_ext FROM assets a
                 JOIN space_assets sa ON sa.asset_id = a.id
                 WHERE a.sha256 = \(bind: sha256)
                   AND (sa.deleted_at IS NULL OR sa.purged_at IS NULL)
                 LIMIT 1) AS "wantedExt",
                EXISTS (
                    SELECT 1 FROM assets a
                    JOIN space_assets sa ON sa.asset_id = a.id
                    WHERE a.sha256 = \(bind: sha256)
                ) AS known
            """).first(decoding: Wanted.self)

        guard let wanted, wanted.known else {
            report.unrecognized.append(file.path)
            return
        }

        let fm = FileManager.default
        if let ext = wanted.wantedExt {
            let blob = store.blobPath(sha256: sha256, fileExtension: ext)
            if fm.fileExists(atPath: blob.path) {
                report.duplicates += 1
                report.freedBytes += file.size
                if !dryRun { try fm.removeItem(atPath: file.path) }
            } else {
                // The last copy of a photo someone can still see. Put it back.
                logger.warning("legacy browse tree: restoring missing blob \(blob.path)")
                report.restored += 1
                if !dryRun {
                    try fm.createDirectory(
                        at: blob.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try fm.moveItem(atPath: file.path, toPath: blob.path)
                }
            }
        } else {
            // Every placement of these bytes was purged: deleted for good by
            // its owner, or by the retention window. This name was all that
            // was left of it.
            report.permanentlyDeleted += 1
            report.freedBytes += file.size
            if !dryRun { try fm.removeItem(atPath: file.path) }
        }
    }

    // MARK: - Helpers

    /// Deepest first, so a folder emptied by its children goes too.
    private static func removeEmptyDirectories(under root: String) {
        let fm = FileManager.default
        var directories: [String] = []
        if let walker = fm.enumerator(atPath: root) {
            while let relative = walker.nextObject() as? String {
                let path = (root as NSString).appendingPathComponent(relative)
                var info = stat()
                if lstat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                    directories.append(path)
                }
            }
        }
        for path in directories.sorted(by: { $0.count > $1.count }) + [root] {
            if (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private static func sha256(ofFile path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs blocking work on a Dispatch thread rather than one of the few the
    /// concurrency runtime shares with every request.
    private static func offPool<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// `FrameStationServer retire-legacy-browse [--dry-run]`
///
/// The server does this by itself at startup; this is for seeing what it will
/// do first, or for doing it again by hand.
struct RetireLegacyBrowseCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "dry-run", help: "Report what would change without touching anything")
        var dryRun: Bool
    }

    var help: String { "Remove the old browse/ tree of hardlinks from the blob store." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let report = try await LegacyBrowseTree.retire(
            store: app.blobStore, sql: app.sql, logger: app.logger, dryRun: signature.dryRun
        ) else {
            context.console.print(
                "No legacy browse tree at \(LegacyBrowseTree.root(of: app.blobStore).path)."
            )
            return
        }
        context.console.print((signature.dryRun ? "Would have " : "") + report.summary)
        for path in report.unrecognized {
            context.console.print("  unrecognized: \(path)")
        }
    }
}
