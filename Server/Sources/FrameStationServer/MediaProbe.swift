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

    static func probe(url: URL, mediaType: MediaType) async throws -> Metadata {
        switch mediaType {
        case .photo: return try await probePhoto(url)
        case .video: return try await probeVideo(url)
        }
    }

    // MARK: - Photos

    private static let exifTags = [
        "-Make", "-Model", "-LensModel", "-LensID",
        "-ISO#", "-FNumber#", "-ExposureTime", "-FocalLength#", "-ExposureCompensation#",
        "-ImageWidth#", "-ImageHeight#",
        "-DateTimeOriginal", "-CreateDate", "-OffsetTimeOriginal",
        "-GPSLatitude#", "-GPSLongitude#", "-GPSLatitudeRef", "-GPSLongitudeRef",
        "-Orientation#", "-MIMEType", "-FileType",
        // Presence of a gain map is what distinguishes Apple Adaptive HDR from
        // an ordinary SDR capture.
        "-HDRGainMapVersion", "-MPImageType", "-ProfileDescription",
    ]

    private static func probePhoto(_ url: URL) async throws -> Metadata {
        let result = try await Shell.runChecked(
            "exiftool", ["-json", "-q"] + exifTags + [url.path], timeout: 60
        )
        guard
            let array = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]],
            let fields = array.first
        else {
            return Metadata()
        }
        var metadata = metadata(from: fields)
        // Best-effort: a full dump that fails must not fail the upload it rides
        // on. `try?` leaves `raw` nil on failure — "not attempted" — so a
        // transient exiftool error is retried later rather than recorded as a
        // file with no metadata. The typed fields above are what the timeline
        // needs; this is only the reference section.
        metadata.raw = try? await fullDump(url)
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

        let stamp = fields.string("DateTimeOriginal") ?? fields.string("CreateDate")
        let offset = fields.string("OffsetTimeOriginal")
        if let stamp {
            (metadata.capturedAt, metadata.capturedTZOffset) = parseEXIFDate(stamp, offset: offset)
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

    // MARK: - Videos

    private static func probeVideo(_ url: URL) async throws -> Metadata {
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
        if let stamp = normalized["creation_time"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            metadata.capturedAt = formatter.date(from: stamp)
                ?? ISO8601DateFormatter().date(from: stamp)
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

        // exiftool reads a video's container the way it reads a photo's EXIF —
        // the QuickTime atoms Synology shows (handler, track dates, graphics
        // mode, the com.apple.quicktime.* keys) all come out of the same pass,
        // so one code path dumps every media type. ffprobe stays above for the
        // curated columns it does better (rotation-aware dimensions, duration).
        metadata.raw = try? await fullDump(url)

        return metadata
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
            // Anything unrecognised is kept under its own cleaned name rather
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

        // Known sections first in a fixed order, then any unrecognised group's
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
    /// colour profiles and the like — a row of "(Binary data 20564 bytes …)" or
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
