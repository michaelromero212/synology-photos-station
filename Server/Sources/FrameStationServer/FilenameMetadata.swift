import Foundation

/// Last-resort metadata read from a file's name.
///
/// A macOS screenshot carries no EXIF capture date, so exiftool finds nothing
/// and the app said "Date unknown" — but the name spells the moment out:
/// `Screenshot 2026-09-02 at 7.32.49 PM.jpg`. When every richer source is
/// silent, the name is the only capture time there is, and it is the one Finder
/// itself shows. The same name is also proof the file is a screenshot.
///
/// Deliberately conservative: it recognizes a few fixed shapes and returns nil
/// for anything else rather than guessing a date out of an arbitrary string. A
/// wrong date is worse than none — it would sort a photo into the wrong day.
enum FilenameMetadata {
    /// The wall-clock capture time named in the file, if the name is one of the
    /// shapes cameras and screenshotters actually use.
    ///
    /// Returned as the components in UTC, so the caller can store it with a zero
    /// offset and have it display as the time written in the name. The true UTC
    /// instant is unknowable from a name — it carries no zone — and the wall
    /// clock is what the person expects to see.
    static func captureDate(from filename: String) -> Date? {
        for pattern in patterns {
            guard let comps = pattern(filename) else { continue }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            if let date = utc.date(from: comps) { return date }
        }
        return nil
    }

    /// Whether the name is a screenshot's. macOS names them "Screenshot …";
    /// iOS Simulator "Simulator Screenshot …". Both start with the word.
    static func isScreenshot(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("screenshot") || lower.hasPrefix("simulator screenshot")
    }

    // MARK: - Patterns

    private static let patterns: [(String) -> DateComponents?] = [
        // macOS: "Screenshot 2026-09-02 at 7.32.49 PM"
        regex(#"(\d{4})-(\d{2})-(\d{2}) at (\d{1,2})\.(\d{2})\.(\d{2})\s*([AP]M)"#) { m in
            components(
                year: m[1], month: m[2], day: m[3],
                hour: m[4], minute: m[5], second: m[6], meridiem: m[7]
            )
        },
        // 24-hour "at": "Screenshot 2026-09-02 at 19.32.49"
        regex(#"(\d{4})-(\d{2})-(\d{2}) at (\d{1,2})\.(\d{2})\.(\d{2})"#) { m in
            components(year: m[1], month: m[2], day: m[3], hour: m[4], minute: m[5], second: m[6])
        },
        // Android / Pixel / generic: "20260902_193249", "PXL_20260902_193249"
        regex(#"(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})"#) { m in
            components(year: m[1], month: m[2], day: m[3], hour: m[4], minute: m[5], second: m[6])
        },
        // "2026-09-02 19.32.49" / "2026-09-02_19-32-49"
        regex(#"(\d{4})-(\d{2})-(\d{2})[ _](\d{2})[.\-:](\d{2})[.\-:](\d{2})"#) { m in
            components(year: m[1], month: m[2], day: m[3], hour: m[4], minute: m[5], second: m[6])
        },
    ]

    private static func components(
        year: String, month: String, day: String,
        hour: String, minute: String, second: String, meridiem: String? = nil
    ) -> DateComponents? {
        guard let y = Int(year), let mo = Int(month), let d = Int(day),
              var h = Int(hour), let mi = Int(minute), let s = Int(second) else { return nil }
        if let meridiem {
            // 12-hour clock: 12 AM is 0, 12 PM is 12, otherwise add 12 for PM.
            if meridiem == "PM", h != 12 { h += 12 }
            if meridiem == "AM", h == 12 { h = 0 }
        }
        guard (1...12).contains(mo), (1...31).contains(d),
              (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) else { return nil }
        return DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// Builds a matcher: run the regex, hand the capture groups (1-indexed) to
    /// `build`. Group 0 is unused so `m[1]` is the first capture, matching how
    /// the patterns above read.
    private static func regex(
        _ p: String, _ build: @escaping ([String]) -> DateComponents?
    ) -> (String) -> DateComponents? {
        let re = try? NSRegularExpression(pattern: p)
        return { name in
            guard let re else { return nil }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = re.firstMatch(in: name, range: range) else { return nil }
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                guard let r = Range(match.range(at: i), in: name) else { return nil }
                groups.append(String(name[r]))
            }
            return build(groups)
        }
    }
}
