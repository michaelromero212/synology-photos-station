import Foundation

/// What a backup run is asked to cover.
///
/// Synology's three, kept because they answer three questions people actually
/// have: pick up where you left off, sweep the whole library, or draw a line
/// under today and only take what comes next.
///
/// Lives here rather than beside the settings screen so the decisions can be
/// tested without a photo library to scan.
public enum BackupRule: String, CaseIterable, Identifiable, Equatable, Sendable {
    case resume
    case scanAll
    case futureOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .resume: return "Resume tasks"
        case .scanAll: return "Scan and back up all photos"
        case .futureOnly: return "Back up future photos"
        }
    }

    public var detail: String {
        switch self {
        case .resume:
            return "Continue the last backup task. Changes to previous photos "
                + "will be backed up as new files."
        case .scanAll:
            return "Backed-up items will be skipped, but items renamed, deleted, "
                + "or moved to another space will be backed up again."
        case .futureOnly:
            return "Back up photos and videos taken from now on. Changes made to "
                + "previous items will also be backed up as new files."
        }
    }

    /// Whether a scan should queue something taken at `takenAt`.
    ///
    /// Only `futureOnly` excludes anything, and only once a line has been
    /// drawn — without a cutoff there is no line, so nothing is held back.
    /// An item with no capture date is taken: there is no evidence it predates
    /// the line, and backing up one photo too many is the recoverable mistake.
    public func queues(takenAt: Date?, cutoff: Date?) -> Bool {
        guard self == .futureOnly, let cutoff else { return true }
        guard let takenAt else { return true }
        return takenAt >= cutoff
    }

    /// Whether a previously failed or skipped item should stand again.
    ///
    /// This is what "scan and back up all photos" buys you over "resume": the
    /// items that fell out of the queue get another attempt. Already-uploaded
    /// items are never re-sent under any rule — the server dedupes by hash, so
    /// it would be pure cost.
    public var retriesPreviousFailures: Bool { self == .scanAll }
}
