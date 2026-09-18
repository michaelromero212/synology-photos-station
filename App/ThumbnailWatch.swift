#if os(iOS)
import Foundation

/// Why a tile ended up with no picture.
///
/// Two rounds of reasoning have now failed to explain grey tiles during a bulk
/// upload — the first blamed the derivation queue, the second blamed the handoff
/// from the uploading tile to the uploaded one. Both were real and both are
/// fixed, and the tiles are still there, which means the remaining cause is
/// something neither of us has thought of. That is the point at which guessing
/// again is the expensive option.
///
/// So this records, for every tile that finishes with nothing to draw, the four
/// facts that distinguish every hypothesis worth having:
///
///   * whether the client believed the NAS had derived it,
///   * whether this phone knew it had the original,
///   * whether that original was still in the camera roll,
///   * and what the server actually said when asked.
///
/// The combination names the cause on sight. A run of `derived · no mapping`
/// means the local shortcut simply doesn't cover those photographs — they were
/// uploaded by another device, or long enough ago that the queue no longer has
/// them. A run of `derived · mapped · server nil` means the NAS is refusing
/// while it is busy, and the retry ladder gives up too early. `not derived ·
/// mapped · on device` means the local paint itself is failing.
///
/// Budgeted and summarised rather than unbounded: a thousand grey tiles would
/// bury the answer in its own evidence. The first few dozen are written out in
/// full and the rest are counted, which is enough to tell a pattern from an
/// accident.
@MainActor
final class ThumbnailWatch {
    static let shared = ThumbnailWatch()

    /// Why the local copy wasn't used.
    enum Local: String {
        /// Drawn from the camera roll — this tile is fine.
        case painted
        /// This phone has no record of having uploaded it.
        case noMapping = "no mapping"
        /// It was this phone's, but the photograph has left the camera roll.
        case notOnDevice = "not on device"
        /// PhotoKit returned nothing.
        case empty
    }

    /// What the NAS said.
    enum Server: String {
        case served
        /// Asked and got nothing — a 202, a failure, or a cancellation.
        case refused
        /// Never asked, because the client believed there was nothing there.
        case notAsked = "not asked"
    }

    private static let detailed = 40
    private var written = 0
    private var counts: [String: Int] = [:]
    private var lastSummary = Date.distantPast

    /// Called only when a cell finishes with no image. A drawn tile costs
    /// nothing here, which matters: this runs inside the grid.
    func blank(assetID: UUID, isDerived: Bool, local: Local, server: Server) {
        let key = "\(isDerived ? "derived" : "not derived") · \(local.rawValue) · server \(server.rawValue)"
        counts[key, default: 0] += 1

        if written < Self.detailed {
            written += 1
            Diagnostics.shared.log(
                .thumbnail, "blank \(assetID.uuidString.prefix(8)) — \(key)"
            )
        }
        // A rolling tally, so a long backup still says which shape dominates
        // without one line per photograph.
        if Date().timeIntervalSince(lastSummary) > 20 {
            lastSummary = Date()
            summarise()
        }
    }

    /// Written on demand too, so exporting the log right after seeing the
    /// problem captures the tally even if the timer hasn't come round.
    func summarise() {
        guard !counts.isEmpty else { return }
        let body = counts.sorted { $0.value > $1.value }
            .map { "\($0.value)× \($0.key)" }
            .joined(separator: ", ")
        Diagnostics.shared.log(.thumbnail, "blank tiles so far — \(body)")
    }

    /// How many photographs this phone can currently draw without the NAS.
    /// Read once when the log is exported: a small number here is itself the
    /// answer to "why didn't the local copy help".
    func noteCoverage(_ count: Int) {
        Diagnostics.shared.log(.thumbnail, "local originals known: \(count)")
    }
}
#endif
