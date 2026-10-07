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
            // Not Synology's wording, which promises that items deleted on the
            // NAS come back. Backup here never puts back a photo someone
            // removed from their library; that would undo a deliberate choice.
            return "Checks every photo and video on this iPhone again and retries "
                + "any that didn't go. Items already backed up aren't sent twice, "
                + "and ones you deleted from your library stay deleted."
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

/// What backup is set to send, as a test each queued file passes or fails.
///
/// A scan already leaves out what the settings exclude, but a file queued
/// before a setting changed stayed queued: switching "Photos Only" on halfway
/// through a backup didn't stop the videos already waiting, and neither did
/// switching to "Back up future photos" stop the older photos. The queue asks
/// this before it sends anything, so a change applies to what is waiting too.
public struct BackupScope: Equatable, Sendable {
    public var includeVideos: Bool
    public var rule: BackupRule
    public var cutoff: Date?

    public init(includeVideos: Bool, rule: BackupRule, cutoff: Date?) {
        self.includeVideos = includeVideos
        self.rule = rule
        self.cutoff = cutoff
    }

    /// Whether a queued file is one to send.
    ///
    /// `isEdit` marks a later edit of a photo already backed up, which the date
    /// line doesn't apply to: "Back up future photos" still sends changes made
    /// to the photos that went before it. A video is a video either way,
    /// a Live Photo's motion included, so "Photos Only" holds it back.
    public func includes(isVideo: Bool, takenAt: Date?, isEdit: Bool = false) -> Bool {
        if isVideo, !includeVideos { return false }
        if isEdit { return true }
        return rule.queues(takenAt: takenAt, cutoff: cutoff)
    }
}
