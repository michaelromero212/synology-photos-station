import Foundation

/// How much of the phone the image cache may take.
///
/// There is deliberately no "no limit" option, which Synology offers. An
/// unbounded cache is the bug this type exists to close, not a preference —
/// and in an app whose whole pitch is about not filling up your phone, a
/// setting that quietly lets it do exactly that is the wrong thing to ship.
///
/// The ceiling is the *pictures*, not the library: the timeline snapshot that
/// makes the grid work offline is metadata and is never evicted by this.
public enum CacheLimit: String, CaseIterable, Identifiable, Sendable {
    case mb250
    case mb500
    case gb1
    case gb2

    public var id: String { rawValue }

    /// 500 MB, matching what Synology ships as its own default. Big enough to
    /// hold thumbnails for a very large library, small enough that nobody goes
    /// looking for where their storage went.
    public static let `default` = CacheLimit.mb500

    public var bytes: Int64 {
        switch self {
        case .mb250: 250 * 1_000_000
        case .mb500: 500 * 1_000_000
        case .gb1: 1_000 * 1_000_000
        case .gb2: 2_000 * 1_000_000
        }
    }

    /// Decimal MB/GB, the same convention the Settings app and every storage
    /// readout on the device use. A cache labelled 500 MB that reports itself
    /// as 476 MB elsewhere reads as a bug.
    public var title: String {
        switch self {
        case .mb250: "250 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        case .gb2: "2 GB"
        }
    }

    public static func from(rawValue: String?) -> CacheLimit {
        rawValue.flatMap(CacheLimit.init(rawValue:)) ?? .default
    }

    /// Formats a measured size for the usage row.
    public static func describe(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
