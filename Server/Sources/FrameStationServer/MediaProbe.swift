import FrameStationAPI
import Foundation
import Vapor

/// Extracts metadata from an original using `exiftool` (photos) and `ffprobe`
/// (videos).
///
/// The device is still authoritative for capture time — `PHAsset.creationDate`
/// is reliable where EXIF is frequently absent, wrong, or timezone-naive — so
/// anything the client supplied at commit wins. This fills the gaps and
/// supplies everything the Information panel shows that the client never knew:
/// lens, exposure, dynamic range.
struct MediaProbe {
    struct Metadata {
        var width: Int?
        var height: Int?
        var durationMs: Int?
        var capturedAt: Date?
        var capturedTZOffset: Int?
        /// True when `capturedAt` is a clock reading with no zone: EXIF's local
        /// time, kept as if it were UTC so that the timeline's local time is
        /// that reading. False when it's a real moment: a zone came with it, or
        /// it's a video's UTC stamp.
        var capturedAtIsClock = false
        /// Which of the file's dates `capturedAt` came from.
        var capturedAtSource: DateSource?
        /// For a video dated by its UTC stamp, its movie header's version: 1
        /// is the 64-bit form, whose date Synology Photos doesn't read.
        var movieHeaderVersion: Int?
        /// The identifier an iPhone gives a Live Photo's photo and video, and
        /// that a copy saved from either keeps. Read as Synology Photos reads
        /// it: from a photo only while it still says an Apple camera made it.
        /// See `ImportGrouping`.
        var liveIdentifier: String?

        enum DateSource {
            case exifOriginal, exifCreate, xmpCreated, appleLocal, quickTimeUTC
        }
        var latitude: Double?
        var longitude: Double?
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        var iso: Int?
        var aperture: Double?
        var shutter: String?
        var focalLength: Double?
        var exposureBias: Double?
        var dynamicRange: String?
        var orientation: Int?
        var isRaw: Bool = false
        var mime: String?
        /// The full technical dump for the Information panel's grouped sections,
        /// already filtered, titled and formatted for display. Separate from the
        /// typed fields above, which the timeline and the camera card read; this
        /// is the "everything else the file records" the sidebar shows.
        ///
        /// Three states, and the difference matters to the backfill: `nil` means
        /// no full dump was attempted (the batch import path, or a probe that
        /// threw), so `exif` is left untouched and stays eligible for a later
        /// pass; `[]` means a dump ran and the file genuinely records nothing,
        /// which is written so the asset stops being re-probed; a non-empty
        /// value is the dump itself.
        var raw: [MetadataGroup]?
    }

    /// `dumpExif: false` skips the full `exiftool -g1` pass — a second exiftool
    /// spawn whose only consumer is the Information panel's reference section.
    /// The commit path passes false so a burst of uploads isn't each blocked on
    /// it; the background metadata job (default true) fills `exif` shortly after.
    static func probe(
        url: URL, mediaType: MediaType, dumpExif: Bool = true
    ) async throws -> Metadata {
        switch mediaType {
        case .photo: return try await probePhoto(url, dumpExif: dumpExif)
        case .video: return try await probeVideo(url, dumpExif: dumpExif)
        }
    }

    // MARK: - Photos

    private static let exifTags = [
        "-Make", "-Model", "-LensModel", "-LensID",
        "-ISO#", "-FNumber#", "-ExposureTime", "-FocalLength#", "-ExposureCompensation#",
        "-ImageWidth#", "-ImageHeight#",
        "-DateTimeOriginal", "-CreateDate", "-OffsetTimeOriginal", "-SubSecTimeOriginal",
        // The zone when OffsetTimeOriginal is missing: an app may have written
        // it beside the other two dates instead. And XMP's DateCreated, the
        // only date some saved and edited pictures carry.
        "-OffsetTimeDigitized", "-OffsetTime", "-XMP:DateCreated",
        "-GPSLatitude#", "-GPSLongitude#", "-GPSLatitudeRef", "-GPSLongitudeRef",
        "-Orientation#", "-MIMEType", "-FileType",
        // Presence of a gain map is what distinguishes Apple Adaptive HDR from
        // an ordinary SDR capture.
        "-HDRGainMapVersion", "-MPImageType", "-ProfileDescription",
        // A Live Photo's identifier, in Apple's maker notes. Older exiftools
        // name it MediaGroupUUID.
        "-ContentIdentifier", "-MediaGroupUUID",
    ]

    private static func probePhoto(_ url: URL, dumpExif: Bool) async throws -> Metadata {
        let arguments = ["-json", "-q"] + exifTags + [url.path]
        let printed: Data
        // On a request path — a commit someone's phone is waiting on — the
        // exiftool already running answers, without Perl starting first. The
        // background worker keeps starting its own: at low priority, where it
        // belongs, and not queued behind the uploads. Anything wrong with the
        // running one and this is the one-shot run it always was.
        if !Shell.isBackground,
           let answer = try? await ExifToolDaemon.shared.run(arguments) {
            printed = answer
        } else {
            printed = try await Shell.runChecked("exiftool", arguments, timeout: 60).stdout
        }
        guard
            let array = try JSONSerialization.jsonObject(with: printed) as? [[String: Any]],
            let fields = array.first
        else {
            return Metadata()
        }
        var metadata = metadata(from: fields)
        // Best-effort: a full dump that fails must not fail the upload it rides
        // on. `try?` leaves `raw` nil on failure — "not attempted" — so a
        // transient exiftool error is retried later rather than recorded as a
        // file with no metadata. The typed fields above are what the timeline
        // needs; this is only the reference section, and it is skipped entirely
        // on the commit path (`dumpExif: false`) so an upload burst isn't each
        // blocked on a second exiftool run.
        if dumpExif { metadata.raw = try? await fullDump(url) }
        return metadata
    }

    /// Probes many photos in a single `exiftool` invocation.
    ///
    /// Process spawn dominates per-file probing: at ~40 ms of startup for ~10 ms
    /// of actual work, importing 100,000 photos one at a time is over an hour of
    /// pure `fork`/`exec`. One process per batch turns that into minutes.
    /// Returns metadata keyed by absolute path; missing entries mean exiftool
    /// had nothing to say about that file.
    static func probePhotoBatch(_ urls: [URL]) async throws -> [String: Metadata] {
        guard !urls.isEmpty else { return [:] }

        let result = try await Shell.runChecked(
            "exiftool",
            ["-json", "-q"] + exifTags + urls.map(\.path),
            timeout: 300
        )
        guard let array = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
            return [:]
        }

        // exiftool echoes SourceFile exactly as passed, so map back by path
        // rather than trusting output order.
        var byPath: [String: Metadata] = [:]
        for fields in array {
            guard let source = fields["SourceFile"] as? String else { continue }
            byPath[source] = metadata(from: fields)
        }
        return byPath
    }

    private static func metadata(from fields: [String: Any]) -> Metadata {
        var metadata = Metadata()
        metadata.width = fields.int("ImageWidth")
        metadata.height = fields.int("ImageHeight")
        metadata.cameraMake = fields.string("Make")
        metadata.cameraModel = fields.string("Model")
        metadata.lens = fields.string("LensModel") ?? fields.string("LensID")
        metadata.iso = fields.int("ISO")
        metadata.aperture = fields.double("FNumber")
        metadata.shutter = fields.string("ExposureTime").map { "\($0) s" }
        metadata.focalLength = fields.double("FocalLength")
        metadata.exposureBias = fields.double("ExposureCompensation")
        metadata.orientation = fields.int("Orientation")
        metadata.mime = fields.string("MIMEType")

        if let fileType = fields.string("FileType")?.uppercased() {
            metadata.isRaw = ["DNG", "CR2", "CR3", "NEF", "ARW", "RAF", "ORF", "RW2"].contains(fileType)
        }

        // A gain map means the file carries Adaptive HDR.
        metadata.dynamicRange = fields["HDRGainMapVersion"] != nil ? "hdr" : "standard"
        metadata.liveIdentifier = photoLiveIdentifier(fields)

        let original = fields.string("DateTimeOriginal")
        // A phone writes the same zone into all three offsets, so the others
        // stand in for OffsetTimeOriginal when it's the one left out.
        let offset = fields.string("OffsetTimeOriginal")
            ?? fields.string("OffsetTimeDigitized") ?? fields.string("OffsetTime")
        if original == nil, fields.string("CreateDate") == nil,
           let created = fields.string("DateCreated"),
           let parsed = parseDateAndZone(created) {
            metadata.capturedAtSource = .xmpCreated
            // XMP writes its zone into the date itself, when it writes one.
            if let zone = parsed.zone {
                metadata.capturedAt = parsed.clock.addingTimeInterval(-TimeInterval(zone))
                metadata.capturedTZOffset = zone
            } else {
                metadata.capturedAt = parsed.clock
                metadata.capturedAtIsClock = true
            }
        } else if let stamp = original ?? fields.string("CreateDate") {
            (metadata.capturedAt, metadata.capturedTZOffset) = parseEXIFDate(stamp, offset: offset)
            metadata.capturedAtIsClock = metadata.capturedAt != nil && metadata.capturedTZOffset == nil
            metadata.capturedAtSource = original != nil ? .exifOriginal : .exifCreate
            // EXIF keeps the fraction of a second in a tag of its own, and
            // without it every photo of a burst is taken at the same instant
            // and the grid can put them in any order. Only with the stamp it
            // belongs to.
            if original != nil,
               let fraction = subsecond(fields.string("SubSecTimeOriginal")) {
                metadata.capturedAt = metadata.capturedAt?.addingTimeInterval(fraction)
            }
        }

        if var latitude = fields.double("GPSLatitude"), var longitude = fields.double("GPSLongitude") {
            // With `#` exiftool may return magnitudes, leaving the hemisphere in
            // the Ref tags. Applying it unconditionally would double-negate an
            // already-signed value, so only correct a positive magnitude.
            if latitude > 0, fields.string("GPSLatitudeRef")?.uppercased().hasPrefix("S") == true {
                latitude = -latitude
            }
            if longitude > 0, fields.string("GPSLongitudeRef")?.uppercased().hasPrefix("W") == true {
                longitude = -longitude
            }
            if latitude.isFinite, longitude.isFinite,
               abs(latitude) <= 90, abs(longitude) <= 180,
               !(latitude == 0 && longitude == 0) {
                metadata.latitude = latitude
                metadata.longitude = longitude
            }
        }

        return metadata
    }

    /// A photo's Live Photo identifier, only while its Make is still Apple's:
    /// Synology Photos kept an edit that had dropped it (`FullSizeRender.jpeg`)
    /// apart from the video carrying the same identifier.
    private static func photoLiveIdentifier(_ fields: [String: Any]) -> String? {
        guard fields.string("Make")?.lowercased().hasPrefix("apple") == true,
              let identifier = fields.string("ContentIdentifier") ?? fields.string("MediaGroupUUID"),
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    /// The Live Photo identifier of each file, photo or video, in one exiftool
    /// run per batch, for files imported before it was read. A file that
    /// carries none maps to "".
    static func liveIdentifiers(_ urls: [URL]) async throws -> [String: String] {
        guard !urls.isEmpty else { return [:] }
        let result = try await Shell.runChecked(
            "exiftool",
            ["-json", "-q", "-Make", "-ContentIdentifier", "-MediaGroupUUID", "-MIMEType"] + urls.map(\.path),
            timeout: 300
        )
        guard let array = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
            return [:]
        }
        var byPath: [String: String] = [:]
        for fields in array {
            guard let source = fields["SourceFile"] as? String else { continue }
            if fields.string("MIMEType")?.hasPrefix("video/") == true {
                byPath[source] = fields.string("ContentIdentifier") ?? ""
            } else {
                byPath[source] = photoLiveIdentifier(fields) ?? ""
            }
        }
        return byPath
    }

    /// `SubSecTimeOriginal` as a fraction of a second: the digits are the ones
    /// after the decimal point, so "098" is 0.098 and "98" is 0.98. exiftool
    /// hands back "980" as the number 980 and "098" as a string, and either way
    /// the digits survive, which is all this reads.
    static func subsecond(_ digits: String?) -> TimeInterval? {
        guard let digits, !digits.isEmpty, digits.count <= 9,
              digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return TimeInterval("0." + digits)
    }

    /// EXIF stamps look like `2026:07:04 15:55:00` with the zone, if present at
    /// all, in a separate `OffsetTimeOriginal` tag.
    static func parseEXIFDate(_ stamp: String, offset: String?) -> (Date?, Int?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var offsetSeconds: Int?
        if let offset, offset.count >= 6 {
            let sign = offset.hasPrefix("-") ? -1 : 1
            let digits = offset.dropFirst()
            let parts = digits.split(separator: ":")
            if parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) {
                offsetSeconds = sign * (hours * 3600 + minutes * 60)
            }
        }

        formatter.timeZone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? TimeZone(identifier: "UTC")
        return (formatter.date(from: stamp), offsetSeconds)
    }

    /// A date written the ISO way or exiftool's: `2023-06-13T22:00:00-0400`,
    /// `2023:06:13 22:00:00.25-04:00`, `…Z`, with no zone, no seconds, or no
    /// time at all. The clock reading, kept as if it were UTC, and the zone in
    /// seconds east of UTC when one is written.
    static func parseDateAndZone(_ value: String) -> (clock: Date, zone: Int?)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let split = text.firstIndex(where: { $0 == "T" || $0 == " " })
        let datePart = split.map { text[..<$0] } ?? Substring(text)
        let ymd = datePart.split(whereSeparator: { $0 == "-" || $0 == ":" }).map { Int($0) }
        guard ymd.count == 3, let year = ymd[0], let month = ymd[1], let day = ymd[2] else {
            return nil
        }

        var hour = 0, minute = 0, second = 0
        var fraction: TimeInterval = 0
        var zone: Int?
        if let split {
            var time = text[text.index(after: split)...]
            if time.hasSuffix("Z") {
                zone = 0
                time = time.dropLast()
            } else if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                guard let parsed = zoneSeconds(time[sign...]) else { return nil }
                zone = parsed
                time = time[..<sign]
            }
            let parts = time.split(separator: ".", maxSplits: 1)
            let hms = (parts.first ?? "").split(separator: ":").map { Int($0) }
            guard (2...3).contains(hms.count), let h = hms[0], let m = hms[1] else { return nil }
            hour = h
            minute = m
            if hms.count == 3 {
                guard let s = hms[2] else { return nil }
                second = s
            }
            if parts.count == 2 { fraction = subsecond(String(parts[1])) ?? 0 }
        }
        guard let seconds = utcSeconds(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ) else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(seconds) + fraction), zone)
    }

    /// A zone written `-0400`, `-04:00` or `-04`: seconds east of UTC.
    static func zoneSeconds(_ text: Substring) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == 4 || digits.count == 2,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.count == 4 ? String(digits.suffix(2)) : "0"),
              hours <= 14, minutes < 60
        else { return nil }
        return (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
    }

    /// A calendar date and clock time as seconds since 1970, read as UTC. By
    /// arithmetic (Howard Hinnant's days_from_civil) rather than a formatter,
    /// which costs about 85 µs to make and isn't safe to share between the
    /// import's workers.
    static func utcSeconds(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Int? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }

    // MARK: - Videos

    private static func probeVideo(_ url: URL, dumpExif: Bool) async throws -> Metadata {
        let result = try await Shell.runChecked(
            "ffprobe",
            ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path],
            timeout: 120
        )
        guard let root = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return Metadata()
        }

        var metadata = Metadata()
        let streams = root["streams"] as? [[String: Any]] ?? []
        if let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            metadata.width = video.int("width")
            metadata.height = video.int("height")

            // Portrait phone video is stored landscape with a rotation matrix;
            // swapping here is what stops the timeline grid laying it out wrong.
            if let rotation = videoRotation(video), rotation == 90 || rotation == 270 {
                swap(&metadata.width, &metadata.height)
            }
        }

        let format = root["format"] as? [String: Any] ?? [:]
        if let duration = format.double("duration") {
            metadata.durationMs = Int(duration * 1000)
        }

        let tags = (format["tags"] as? [String: Any]) ?? [:]
        let normalized = Dictionary(uniqueKeysWithValues: tags.map { ($0.key.lowercased(), $0.value) })
        // An iPhone writes the moment twice: in UTC (creation_time) and as the
        // local time with its zone (com.apple.quicktime.creationdate). The zone
        // is what puts a video in its own hour and on its own day: the UTC
        // stamp alone, kept as local time, put every imported video four or
        // five hours late, and an evening one on the next day. And for a
        // trimmed or exported clip, creation_time is when that happened.
        if let local = normalized["com.apple.quicktime.creationdate"] as? String,
           let parsed = parseDateAndZone(local), let zone = parsed.zone {
            metadata.capturedAt = parsed.clock.addingTimeInterval(-TimeInterval(zone))
            metadata.capturedTZOffset = zone
            metadata.capturedAtSource = .appleLocal
        } else if let stamp = normalized["creation_time"] as? String {
            // The movie header's own stamp, the one Synology Photos goes by.
            // An editor such as CapCut also writes a creation_time key, which
            // ffprobe reports instead, minutes from the header's.
            if let header = movieHeader(url) {
                metadata.capturedAt = header.created
                metadata.movieHeaderVersion = header.version
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                metadata.capturedAt = formatter.date(from: stamp)
                    ?? ISO8601DateFormatter().date(from: stamp)
            }
            if metadata.capturedAt != nil { metadata.capturedAtSource = .quickTimeUTC }
        }
        // Apple writes GPS as an ISO-6709 string, e.g. "+38.3487-077.9797+019.694/".
        if let location = (normalized["com.apple.quicktime.location.iso6709"] as? String)
            ?? (normalized["location"] as? String),
           let coordinate = parseISO6709(location) {
            metadata.latitude = coordinate.latitude
            metadata.longitude = coordinate.longitude
        }
        metadata.cameraMake = normalized["com.apple.quicktime.make"] as? String
        metadata.cameraModel = normalized["com.apple.quicktime.model"] as? String
        if let identifier = normalized["com.apple.quicktime.content.identifier"] as? String, !identifier.isEmpty {
            metadata.liveIdentifier = identifier
        }

        // exiftool reads a video's container the way it reads a photo's EXIF —
        // the QuickTime atoms Synology shows (handler, track dates, graphics
        // mode, the com.apple.quicktime.* keys) all come out of the same pass,
        // so one code path dumps every media type. ffprobe stays above for the
        // curated columns it does better (rotation-aware dimensions, duration).
        // Skipped on the commit path; the background metadata job fills it in.
        if dumpExif { metadata.raw = try? await fullDump(url) }

        return metadata
    }

    /// A QuickTime or MP4 file's movie header (`moov` → `mvhd`): its version
    /// and the moment it records, nil when there's no header to read. ffprobe
    /// reads both versions' dates and doesn't say which it read, and reports
    /// a creation_time key over the header's. Only box headers are read, so a
    /// header after the media costs a seek, not the file.
    static func movieHeader(_ url: URL) -> (version: Int, created: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        /// The box at `offset`: its type, header length and size.
        func box(at offset: UInt64, before limit: UInt64) -> (type: String, header: UInt64, size: UInt64)? {
            guard offset + 8 <= limit, (try? handle.seek(toOffset: offset)) != nil,
                  let read = try? handle.read(upToCount: 16), read.count >= 8
            else { return nil }
            let bytes = [UInt8](read)
            func number(_ range: Range<Int>) -> UInt64 { bytes[range].reduce(0) { $0 << 8 | UInt64($1) } }
            var size = number(0..<4)
            var header: UInt64 = 8
            if size == 1 {
                guard bytes.count >= 16 else { return nil }
                size = number(8..<16)
                header = 16
            } else if size == 0 {
                size = limit - offset
            }
            guard size >= header, size <= limit - offset else { return nil }
            return (String(decoding: bytes[4..<8], as: UTF8.self), header, size)
        }

        var offset: UInt64 = 0
        while let top = box(at: offset, before: end) {
            if top.type == "moov" {
                let moovEnd = offset + top.size
                var child = offset + top.header
                while let inner = box(at: child, before: moovEnd) {
                    if inner.type == "mvhd" {
                        guard (try? handle.seek(toOffset: child + inner.header)) != nil,
                              let read = try? handle.read(upToCount: 12), let version = read.first
                        else { return nil }
                        // The version, three bytes of flags, then the creation
                        // time: seconds since 1904, 64 bits wide in version 1.
                        let bytes = [UInt8](read)
                        let width = version == 1 ? 8 : 4
                        guard bytes.count >= 4 + width else { return (Int(version), nil) }
                        let seconds = bytes[4..<4 + width].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                        return (Int(version), headerDate(seconds))
                    }
                    child += inner.size
                }
                return nil
            }
            offset += top.size
        }
        return nil
    }

    /// A movie header's creation time as ffmpeg reads it: none when it's
    /// zero, and a value too small to count from 1904 is a writer's Unix time.
    private static func headerDate(_ seconds: UInt64) -> Date? {
        guard seconds > 0 else { return nil }
        let since1970 = seconds >= 2_082_844_800 ? seconds - 2_082_844_800 : seconds
        return Date(timeIntervalSince1970: TimeInterval(since1970))
    }

    private static func videoRotation(_ stream: [String: Any]) -> Int? {
        if let tags = stream["tags"] as? [String: Any],
           let rotate = tags["rotate"] as? String, let value = Int(rotate) {
            return abs(value) % 360
        }
        if let sideData = stream["side_data_list"] as? [[String: Any]] {
            for entry in sideData {
                if let rotation = entry["rotation"] as? Double {
                    return abs(Int(rotation)) % 360
                }
                if let rotation = entry["rotation"] as? Int {
                    return abs(rotation) % 360
                }
            }
        }
        return nil
    }

    static func parseISO6709(_ value: String) -> (latitude: Double, longitude: Double)? {
        // Signed decimal runs: +38.3487-077.9797+019.694/
        var numbers: [Double] = []
        var current = ""
        for character in value {
            if character == "+" || character == "-" {
                if let parsed = Double(current) { numbers.append(parsed) }
                current = String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            } else {
                if let parsed = Double(current) { numbers.append(parsed) }
                current = ""
            }
        }
        if let parsed = Double(current) { numbers.append(parsed) }

        guard numbers.count >= 2,
              abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1])
    }

    // MARK: - Full dump (the sidebar's technical section)

    /// Every meaningful tag the file records, grouped for the Information panel.
    ///
    /// One `exiftool -g1` pass — grouped by exiftool's own family-1 groups
    /// (`ExifIFD`, `GPS`, `QuickTime`, `Track1`, …) — folded into a handful of
    /// friendly sections. exiftool reads stills and video alike, so this covers
    /// every media type; the curated typed columns come from the passes above.
    ///
    /// `-struct` is deliberately *off*: it nests structured tags into JSON
    /// objects, and a flat scalar per row is exactly what a two-column panel
    /// wants. `-c "%+.6f"` prints GPS as signed decimals rather than
    /// "38 deg 44' 16.80\" N", which reads better and matches the map.
    static func fullDump(_ url: URL) async throws -> [MetadataGroup] {
        let result = try await Shell.runChecked(
            "exiftool", ["-json", "-g1", "-c", "%+.6f", url.path], timeout: 60
        )
        guard
            let array = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]],
            let root = array.first
        else {
            return []
        }
        return groups(from: root)
    }

    /// exiftool family-1 groups, in display order, keyed to a friendly section
    /// title. A group that maps to nil is dropped wholesale — pure filesystem
    /// facts and exiftool's own bookkeeping, which no one browsing a photo wants.
    private static func section(forGroup group: String) -> String? {
        switch group {
        case "System", "ExifTool": return nil
        case "File", "Composite": return "General"
        case "GPS": return "Location"
        case "IFD0", "IFD1", "SubIFD", "ExifIFD", "InteropIFD", "MakerNotes", "Apple":
            return "Camera"
        case "PNG", "JFIF", "GIF", "BMP", "PSD": return "Image"
        default:
            if group.hasPrefix("Track") || group.hasPrefix("QuickTime")
                || group.hasPrefix("Keys") || group.hasPrefix("ItemList")
                || group.hasPrefix("UserData") || group.hasPrefix("Meta")
                || group.hasPrefix("Matroska") || group.hasPrefix("RIFF")
                || group.hasPrefix("H264") || group.hasPrefix("MPEG")
                || group.hasPrefix("Flash") {
                return "Media"
            }
            if group.hasPrefix("XMP") || group.hasPrefix("ICC")
                || group.hasPrefix("IPTC") || group.hasPrefix("Photoshop")
                || group.hasPrefix("APP") || group == "Adobe" {
                return "Advanced"
            }
            // Anything unrecognized is kept under its own cleaned name rather
            // than lost — a camera maker's private group is exactly the kind of
            // thing someone digs into the panel to find.
            return spaced(group)
        }
    }

    /// The order sections appear in the panel. Titles not listed (an unknown
    /// group's own name) follow, alphabetically.
    private static let sectionOrder = ["General", "Camera", "Media", "Image", "Location", "Advanced"]

    /// Filesystem and bookkeeping keys that survive their group — mostly from
    /// `File` — and say nothing about the photograph.
    private static let droppedKeys: Set<String> = [
        "Directory", "FileName", "FilePermissions", "FileModifyDate",
        "FileAccessDate", "FileInodeChangeDate", "FileTypeExtension",
        "ExifByteOrder", "CurrentIPTCDigest", "SourceFile", "Warning",
    ]

    private static func groups(from root: [String: Any]) -> [MetadataGroup] {
        var bySection: [String: [MetadataEntry]] = [:]
        // Dedupe within a section: several exiftool groups fold into "Camera",
        // and Make/Model turning up in both IFD0 and MakerNotes would show the
        // same row twice.
        var seen: [String: Set<String>] = [:]

        for (group, value) in root {
            guard let title = section(forGroup: group),
                  let fields = value as? [String: Any] else { continue }
            for (key, rawValue) in fields {
                guard !droppedKeys.contains(key),
                      let text = displayValue(rawValue),
                      !isNoisy(text) else { continue }
                let label = spaced(key)
                if seen[title, default: []].contains(label) { continue }
                seen[title, default: []].insert(label)
                bySection[title, default: []].append(MetadataEntry(label: label, value: text))
            }
        }

        // Known sections first in a fixed order, then any unrecognized group's
        // own title alphabetically. Rows within a section are sorted so the
        // panel is stable across probes rather than in hash order.
        let known = sectionOrder.filter { bySection[$0] != nil }
        let extra = bySection.keys.filter { !sectionOrder.contains($0) }.sorted()
        return (known + extra).compactMap { title in
            guard let entries = bySection[title], !entries.isEmpty else { return nil }
            return MetadataGroup(
                title: title,
                entries: entries.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            )
        }
    }

    /// A JSON value as one line of display text, or nil to skip it.
    private static func displayValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let parts = array.compactMap { displayValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            // A nested object (rare without -struct) isn't a single line; drop it.
            return nil
        }
    }

    /// Binary blobs and over-long values exiftool emits for embedded thumbnails,
    /// color profiles and the like — a row of "(Binary data 20564 bytes …)" or
    /// a 4 KB base64 string is noise, not information.
    private static func isNoisy(_ text: String) -> Bool {
        text.count > 160
            || text.hasPrefix("(Binary data")
            || text.hasPrefix("base64:")
            || text.hasPrefix("use -b option")
    }

    /// `HandlerVendorID` → `Handler Vendor ID`, `MIMEType` → `MIME Type`,
    /// `GPSLatitude` → `GPS Latitude`. A space before an uppercase that starts a
    /// word (follows a lowercase, or ends an acronym before a lowercase), and
    /// before a digit run, so the raw tag names read as labels.
    static func spaced(_ identifier: String) -> String {
        var out = ""
        let chars = Array(identifier)
        for index in chars.indices {
            let char = chars[index]
            if index > 0 {
                let prev = chars[index - 1]
                let startsWord = char.isUppercase && !prev.isUppercase
                let endsAcronym = char.isUppercase && prev.isUppercase
                    && index + 1 < chars.count && chars[index + 1].isLowercase
                let startsNumber = char.isNumber && !prev.isNumber
                if startsWord || endsAcronym || startsNumber {
                    out.append(" ")
                }
            }
            out.append(char)
        }
        return out
    }
}

// MARK: - Loose JSON access

private extension [String: Any] {
    func string(_ key: String) -> String? {
        if let value = self[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }
}
