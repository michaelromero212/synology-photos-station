import Foundation
import Vapor

/// `FrameStationServer regroup` — groups an imported library's files into grid
/// items the way Synology Photos does (`ImportGrouping`), for a library that
/// came in before the import did it. Reads each file's Live Photo identifier
/// once, about half an hour for 20,000 files on the NAS, and changes only which
/// files are shown together: no file, date or name. A row another library
/// shows too keeps its grouping, and so does what's grouped with it.
struct RegroupCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "path", short: "p", help: "The folder it was imported from, spelled as for the import")
        var path: String?

        @Option(name: "space", short: "s", help: "The library it was imported into")
        var space: String?

        @Option(name: "synology", help: "Synology Photos' items, from Scripts/export-synology-dates.sh: split and join as it did")
        var synology: String?

        @Flag(name: "dry-run", help: "Say what would change, changing no grouping (identifiers read are still recorded)")
        var dryRun: Bool
    }

    var help: String { "Group an imported library's files into items as Synology Photos does." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let path = signature.path,
              let space = signature.space.flatMap(UUID.init(uuidString:))
        else {
            throw Abort(.badRequest, reason: "--path and --space (a library's id) are both required.")
        }
        let console = context.console
        let synologyItems = try signature.synology.map(ImportGrouping.synologyItems(from:))
        console.info("Grouping what was imported from \(path)…")
        let summary = try await ImportGrouping.regroup(
            space: space, root: path, app: context.application, synologyItems: synologyItems,
            write: !signature.dryRun
        ) { done, total in
            if done % 1600 == 0 || done == total { console.info("  identifiers read: \(done)/\(total)") }
        }
        let root = path.hasSuffix("/") ? path : path + "/"
        console.info("")
        console.info("  Identifiers read from files:  \(summary.read)")
        console.info("  Items of more than one file:  \(summary.items)")
        console.info("  Of them Live Photos:          \(summary.livePhotos)")
        console.info("  Files kept with another:      \(summary.stacked)")
        console.info("  Kept with the phone's version: \(summary.keptWithPhone)")
        console.info("  Files whose grouping changed: \(summary.changed)")
        for path in summary.changedPaths.prefix(20) { console.info("    " + path.replacingOccurrences(of: root, with: "")) }
        if summary.leftShared > 0 {
            console.info("  Left as they were, with a row another library shows: \(summary.leftShared)")
            for path in summary.leftPaths.prefix(20) { console.info("    " + path.replacingOccurrences(of: root, with: "")) }
        }
        if signature.dryRun {
            console.info("")
            console.info("Dry run — no grouping changed.")
        }
    }
}
