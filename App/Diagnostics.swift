import Foundation
#if os(iOS)
import UIKit
#endif

/// An in-app record of what playback actually did, exportable as Markdown.
///
/// Exists because the console is not available where the problem is. Cellular
/// playback cannot be watched from Xcode — the phone is off the cable by
/// definition — and that is precisely the case still to be got right. So the app
/// keeps its own log and hands it over as a file.
///
/// Deliberately *not* `print`. These entries are structured, survive the debug
/// session, and are summarized into measurements at the end rather than being a
/// wall of lines to read by eye.
@MainActor
final class Diagnostics {
    static let shared = Diagnostics()

    enum Category: String {
        case network = "Network"
        case playback = "Playback"
        case stall = "Stall"
        case action = "Action"
        case quality = "Quality"
        case measurement = "Measurement"
        case launch = "Launch"
        /// Anything that moves the grid when the user didn't. See `LayoutWatch`.
        case layout = "Layout"
        /// A tile that ended up with no picture, and why. See `ThumbnailWatch`.
        case thumbnail = "Thumbnail"
        /// Being woken to finish a backup, and what came of it. The only record
        /// of a silent push there is: it arrives while the phone is in a pocket,
        /// where the console cannot reach. See `BackupNudger` on the server.
        case backup = "Backup"

        /// Read at a glance when skimming a long log.
        var symbol: String {
            switch self {
            case .network: return "📶"
            case .playback: return "▶️"
            case .stall: return "⚠️"
            case .action: return "👆"
            case .quality: return "🎚"
            case .measurement: return "📊"
            case .launch: return "🚀"
            case .layout: return "📐"
            case .thumbnail: return "🖼️"
            case .backup: return "☁️"
            }
        }
    }

    struct Entry {
        let at: Date
        let category: Category
        let message: String
    }

    /// Bounded, because this runs for the life of the app and a stalling video
    /// is chatty. Oldest fall off the front; a report is only ever interesting
    /// from the last few minutes anyway.
    private static let capacity = 3000
    /// How far over capacity to run before trimming, so the shift is paid
    /// once per `slack` entries rather than on every append.
    private static let slack = 256
    private var entries: [Entry] = []
    private let startedAt = Date()

    /// Flipped off in a release build's UI, but the machinery stays: the whole
    /// point is to gather evidence from a phone that is not plugged in.
    /// Trimmed in batches, not one at a time.
    ///
    /// `removeFirst` on an Array shifts every remaining element, so trimming on
    /// each append meant that once the buffer was full *every* log call moved
    /// three thousand entries — on the main actor, at exactly the moment a
    /// network change makes the app noisiest. Dropping a block at a time
    /// amortises that to nothing.
    func log(_ category: Category, _ message: String) {
        entries.append(Entry(at: Date(), category: category, message: message))
        if entries.count > Self.capacity + Self.slack {
            entries.removeFirst(Self.slack)
        }
    }

    func clear() { entries.removeAll() }

    var count: Int { entries.count }

    // MARK: - Report

    /// The whole log as a Markdown document.
    ///
    /// Written to be read by someone diagnosing a stutter: what the device and
    /// connection were, then the measurements that say whether the bytes kept
    /// up, then the timeline. Summary first because the summary usually answers
    /// it and the timeline only says when.
    func markdown() -> String {
        var out = "# FrameStation playback diagnostics\n\n"
        out += "Exported \(Self.stamp.string(from: Date()))  \n"
        out += "Covering \(Self.duration(since: startedAt)) since launch, "
        out += "\(entries.count) events\n\n"

        out += "## Device\n\n"
        for (key, value) in Self.deviceFacts() {
            out += "- **\(key):** \(value)\n"
        }
        out += "\n"

        out += "## What to look for\n\n"
        out += """
        `observedBitrate` is what the connection actually delivered. Compare it
        with the stream's own bitrate: if observed is at or below it, the link
        cannot keep ahead of playback and stalls are arithmetic, not a bug.
        `Stalls` counts them. A rising `Dropped frames` with a healthy bitrate
        means the opposite — the bytes arrived and the device could not draw
        them.

        """
        out += "\n"

        out += "## Timeline\n\n"
        if entries.isEmpty {
            out += "_No events recorded._\n"
        } else {
            out += "| Time | | Event |\n|---|---|---|\n"
            for entry in entries {
                let time = Self.clock.string(from: entry.at)
                // Pipes would break the table, and a URL or a filename can
                // carry one.
                let safe = entry.message.replacingOccurrences(of: "|", with: "\\|")
                out += "| `\(time)` | \(entry.category.symbol) | \(safe) |\n"
            }
        }
        out += "\n---\n\nGenerated by FrameStation.\n"
        return out
    }

    /// Writes the report somewhere the share sheet can reach it.
    func exportFile() throws -> URL {
        let name = "framestation-diagnostics-\(Self.fileStamp.string(from: Date())).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try markdown().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Formatting

    private static func deviceFacts() -> [(String, String)] {
        var facts: [(String, String)] = []
        #if os(iOS)
        let device = UIDevice.current
        facts.append(("Device", device.model))
        facts.append(("System", "\(device.systemName) \(device.systemVersion)"))
        #endif
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        facts.append(("App", "\(version) (\(build))"))
        return facts
    }

    private static func duration(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}

/// Records what each request cost at the connection level.
///
/// Built for one question the app could not otherwise answer: where the seconds
/// go when it launches on cellular but not on wi-fi. `URLSessionTaskMetrics`
/// breaks a request into DNS, TCP and TLS, and — the part that matters here —
/// reports the address actually connected to, so "it chose IPv6 and waited for
/// a timeout before falling back" stops being a theory.
///
/// Only slow or first-of-connection requests are logged. Every request would
/// bury the timeline, and a reused connection has nothing interesting to say.
final class ConnectionMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Below this a request is simply working, and saying so is noise.
    private static let interestingSeconds: TimeInterval = 0.5
    /// Guards `lastFresh`. Delegate callbacks arrive on a session-owned queue,
    /// which is serial in practice but not promised to be.
    private let gate = NSLock()
    private var lastFresh = Date.distantPast

    private func permitFreshLog() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        guard Date().timeIntervalSince(lastFresh) > 1 else { return false }
        lastFresh = Date()
        return true
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let last = metrics.transactionMetrics.last else { return }
        let total = metrics.taskInterval.duration
        // Slow requests always; new connections at most once a second.
        //
        // Logging every fresh connection sounds cheap until the network changes
        // underfoot: every connection is remade at once, so a grid mid-scroll
        // fired this once per in-flight thumbnail, each hopping to the main
        // actor — a burst landing exactly when the UI could least afford it.
        let slow = total >= Self.interestingSeconds
        guard slow || (!last.isReusedConnection && permitFreshLog()) else { return }

        // The path, not the address. This log is meant to be shared, and the
        // NAS's hostname and address are not ours to scatter about — the family
        // is the part that answers the question anyway.
        let family: String
        switch last.remoteAddress {
        case let address? where address.contains("."): family = "IPv4"
        case let address? where address.contains(":"): family = "IPv6"
        default: family = "unknown"
        }

        var parts = ["\(family)"]
        func span(_ from: Date?, _ to: Date?, _ label: String) {
            guard let from, let to else { return }
            let seconds = to.timeIntervalSince(from)
            guard seconds > 0.01 else { return }
            parts.append(String(format: "%@ %.2fs", label, seconds))
        }
        span(last.domainLookupStartDate, last.domainLookupEndDate, "dns")
        span(last.connectStartDate, last.connectEndDate, "tcp")
        span(last.secureConnectionStartDate, last.secureConnectionEndDate, "tls")
        if last.isReusedConnection { parts.append("reused") }
        parts.append(String(format: "total %.2fs", total))

        let path = task.originalRequest?.url?.path ?? "?"
        let address = last.remoteAddress
        Task { @MainActor in
            // Locality first: this is what `Auto` decides on, and it wants the
            // answer from the address actually reached.
            if let address { NetworkLocality.shared.noteServerAddress(address) }
            Diagnostics.shared.log(.network, "\(path) — " + parts.joined(separator: ", "))
        }
    }
}

/// The session every API call goes through, so the metrics above are collected.
///
/// A plain `.default` configuration — the same behavior `URLSession.shared`
/// gave — with a delegate attached, which `shared` does not allow.
@MainActor
enum InstrumentedSession {
    static let shared: URLSession = URLSession(
        configuration: .default, delegate: ConnectionMetrics(), delegateQueue: nil
    )
}
