import Foundation
import Vapor

/// The paths a copy-on-write clone takes between the blob store and a home.
///
/// DSM's kernel refuses a clone between two separately mounted folders, even
/// two on the same Btrfs volume, and in the server container the blob store
/// (`/data`) and the homes (`/homes`) are separate mounts. So until October
/// 2026 every File Station copy failed to clone, and `cp` left an empty file
/// in its place. Compose now also mounts the whole volume once and says where
/// those two folders are inside it. A clone goes through those paths, which
/// the kernel sees as a single mount. Everything else keeps using `/data` and
/// `/homes`, so no stored path changes.
///
/// Left unset, as on the dev stack and in the smoke tests, every path is used
/// as it is.
struct CloneRoute: Sendable {
    private struct Alias: Sendable {
        /// Where the folder is mounted, such as `/data`.
        let root: String
        /// The same folder inside the single volume mount, such as
        /// `/volume1/docker/framestation`.
        let viaVolume: String
    }

    private let aliases: [Alias]

    /// No aliases: every path is used as it is.
    init() {
        aliases = []
    }

    init(blobRoot: String, blobRootViaVolume: String?, homesRoot: String, homesRootViaVolume: String?) {
        func trimmed(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        var aliases: [Alias] = []
        if let via = blobRootViaVolume, !via.isEmpty {
            aliases.append(Alias(root: trimmed(blobRoot), viaVolume: trimmed(via)))
        }
        if let via = homesRootViaVolume, !via.isEmpty {
            aliases.append(Alias(root: trimmed(homesRoot), viaVolume: trimmed(via)))
        }
        self.aliases = aliases
    }

    static func fromEnvironment(blobRoot: String, homesRoot: String) -> CloneRoute {
        CloneRoute(
            blobRoot: blobRoot,
            blobRootViaVolume: Environment.get("FRAMESTATION_CLONE_BLOB_ROOT"),
            homesRoot: homesRoot,
            homesRootViaVolume: Environment.get("FRAMESTATION_CLONE_HOMES_ROOT")
        )
    }

    /// `path`, reached through the volume mount when it's under an aliased root.
    func resolve(_ path: String) -> String {
        for alias in aliases where path == alias.root || path.hasPrefix(alias.root + "/") {
            return alias.viaVolume + path.dropFirst(alias.root.count)
        }
        return path
    }

    /// `cp --reflink=always`, which fails rather than quietly copying. macOS
    /// spells it `-c` (clonefile), for the dev stack.
    ///
    /// When the clone fails, GNU `cp` has already created `destination` and
    /// leaves it there empty. Removing it is the caller's job.
    func clone(_ source: String, to destination: String) async -> Bool {
        #if os(macOS)
        let flag = "-c"
        #else
        let flag = "--reflink=always"
        #endif
        guard let result = try? await Shell.run("cp", [flag, resolve(source), resolve(destination)])
        else { return false }
        return result.status == 0
    }
}
