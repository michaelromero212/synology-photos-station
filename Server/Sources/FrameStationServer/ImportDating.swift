import Foundation

/// When an imported file was taken, read from the file itself, in the three
/// forms the timeline keeps: the moment, its zone, and the local clock reading
/// the grid orders by. Nothing in the file is changed; this is only how its
/// dates are read.
///
/// A file can say less than that. In one person's Synology library (the
/// 2026-10-24 audit, `Scripts/audit-synology-library.sh`) about 8,800 of 19,800
/// files came in at the wrong local time: every video, whose UTC stamp was
/// kept as if it were local while the local time and zone an iPhone records
/// went unread, and the photos with no date inside or only an XMP one, dated
/// by their modification time the same way. Each sat four or five hours late,
/// and an evening one on the next day.
///
/// The dates read are the ones Synology Photos goes by, so a library comes
/// over in the order it shows there: a camera's date (EXIF), an iPhone video's
/// own local time, a video's UTC stamp as its movie header records it (not a
/// creation_time key a video editor adds, minutes off), and for anything else, its
/// modification time, which Synology's backup sets from the phone's library.
/// Synology passes over an XMP date, and a UTC stamp in the 64-bit form of a
/// movie header, which it doesn't read, so this does too. Comparing every file
/// of one library with Synology (2026-10-24) settled each: of the 1,372 videos
/// with a stamp and no local time, every one matched but a second copy of one
/// of them (see `ImportCommand`), and the two whose stamp Synology passed over
/// were the only ones with a 64-bit header. A time with no zone is shown in
/// the household's (`--time-zone`), as Synology shows it in the NAS's.
struct ImportDating {
    var capturedAt: Date
    /// The zone stored with it: the file's own, or the household's when the
    /// file's date has none. Stored either way, because the background
    /// metadata pass fills an empty one from whatever zone the file has, and
    /// an XMP date's zone passed over here would move the photo.
    var zone: Int?
    /// The household's zone, when that's where `zone` came from.
    var fallbackZone: Int?
    /// The local clock reading, kept as if it were UTC.
    var local: Date
    var source: Source

    enum Source: String, CaseIterable {
        case fileZone = "its date and zone"
        case fileClock = "its date, with no zone"
        case fileUTC = "its date, in UTC"
        case modified = "its modification time"
    }

    static func resolve(
        probe: MediaProbe.Metadata, modifiedAt: Date, household: TimeZone?
    ) -> ImportDating {
        if !passesOver(probe), let own = fileDate(probe, household: household) {
            return own
        }
        return modified(modifiedAt, household: household)
    }

    /// The file's own date, whether or not Synology Photos goes by it; nil
    /// when the file records none.
    static func fileDate(_ probe: MediaProbe.Metadata, household: TimeZone?) -> ImportDating? {
        guard let captured = probe.capturedAt else { return nil }
        if let zone = probe.capturedTZOffset {
            return ImportDating(
                capturedAt: captured, zone: zone, fallbackZone: nil,
                local: captured.addingTimeInterval(TimeInterval(zone)), source: .fileZone
            )
        }
        if probe.capturedAtIsClock {
            return fromClock(captured, household: household)
        }
        return fromMoment(captured, household: household, source: .fileUTC)
    }

    /// The modification time, which Synology's backup sets from the phone's
    /// library.
    static func modified(_ modifiedAt: Date, household: TimeZone?) -> ImportDating {
        fromMoment(modifiedAt, household: household, source: .modified)
    }

    /// Whether Synology Photos goes by the modification time rather than the
    /// file's date: an XMP date always, and a UTC stamp in a version 1 movie
    /// header.
    static func passesOver(_ probe: MediaProbe.Metadata) -> Bool {
        switch probe.capturedAtSource {
        case .xmpCreated: return true
        case .quickTimeUTC: return probe.movieHeaderVersion == 1
        default: return false
        }
    }

    /// A local clock reading with no zone. It's already the local time; the
    /// household's zone at that time only places the moment.
    private static func fromClock(_ local: Date, household: TimeZone?) -> ImportDating {
        guard let household else {
            return ImportDating(capturedAt: local, zone: nil, fallbackZone: nil,
                                local: local, source: .fileClock)
        }
        // The offset in force at that local time: asked with the reading, then
        // again at the moment that gives, which settles it except inside the
        // hour a daylight-saving change skips or repeats.
        let first = household.secondsFromGMT(for: local)
        let offset = household.secondsFromGMT(for: local.addingTimeInterval(-TimeInterval(first)))
        return ImportDating(
            capturedAt: local.addingTimeInterval(-TimeInterval(offset)), zone: offset,
            fallbackZone: offset, local: local, source: .fileClock
        )
    }

    /// A real moment with no zone, a UTC stamp or the modification time:
    /// local time is the household's at that moment.
    private static func fromMoment(_ moment: Date, household: TimeZone?, source: Source) -> ImportDating {
        let offset = household?.secondsFromGMT(for: moment)
        return ImportDating(
            capturedAt: moment, zone: offset, fallbackZone: offset,
            local: moment.addingTimeInterval(TimeInterval(offset ?? 0)), source: source
        )
    }
}
