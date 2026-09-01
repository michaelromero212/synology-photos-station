import Foundation

/// The days of the year that already mean something.
///
/// The cheapest meaning in the whole library, and the reason it comes first:
/// forty photographs on the 25th of December is Christmas, and knowing that
/// takes a lookup table rather than a model. No inference, no training, no
/// overnight job — and it works on the entire back catalogue the moment it
/// ships, including the scans from before anyone had a phone.
///
/// Deliberately a short list. Every entry here has to be a day people
/// *photograph*: Thanksgiving and Halloween earn their place, Presidents' Day
/// does not, and naming an ordinary busy Monday in February after a public
/// holiday nobody marked would be worse than leaving it called what it is.
///
/// US-centric, which matches the household this is for. The two tables below
/// are the whole of that assumption — a second region is a second pair of
/// tables, not a rewrite.
enum Holidays {
    /// Days that fall on the same date every year.
    private static let fixed: [(monthDay: String, name: String)] = [
        ("01-01", "New Year's Day"),
        ("02-14", "Valentine's Day"),
        ("07-04", "Independence Day"),
        ("10-31", "Halloween"),
        ("12-24", "Christmas Eve"),
        ("12-25", "Christmas Day"),
        ("12-31", "New Year's Eve"),
    ]

    /// Days that move, and the rule that finds them.
    ///
    /// Easter is the awkward one — it is neither a fixed date nor an nth
    /// weekday, but the Gregorian computus below is exact and has no lookup
    /// table to go stale.
    private static func moving(in year: Int) -> [(day: String, name: String)] {
        var result: [(String, String)] = []
        if let easter = easterSunday(year) { result.append((easter, "Easter")) }
        if let d = nthWeekday(2, .sunday, month: 5, year: year) { result.append((d, "Mother's Day")) }
        if let d = lastWeekday(.monday, month: 5, year: year) { result.append((d, "Memorial Day")) }
        if let d = nthWeekday(3, .sunday, month: 6, year: year) { result.append((d, "Father's Day")) }
        if let d = nthWeekday(1, .monday, month: 9, year: year) { result.append((d, "Labor Day")) }
        if let d = nthWeekday(4, .thursday, month: 11, year: year) { result.append((d, "Thanksgiving")) }
        return result
    }

    enum Weekday: Int {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    }

    /// Every named day in the given years, keyed by `YYYY-MM-DD`.
    ///
    /// Built for the years the library actually holds rather than a fixed
    /// window: a family with scans going back to the fifties should get their
    /// Christmases too, and a library with three years in it shouldn't pay to
    /// compute eighty.
    static func table(forYears years: [Int]) -> [String: String] {
        var table: [String: String] = [:]
        for year in years {
            for entry in fixed {
                table["\(year)-\(entry.monthDay)"] = entry.name
            }
            for entry in moving(in: year) {
                table[entry.day] = entry.name
            }
        }
        return table
    }

    // MARK: - The arithmetic

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func key(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "The third Sunday in June."
    static func nthWeekday(_ n: Int, _ weekday: Weekday, month: Int, year: Int) -> String? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.weekday = weekday.rawValue
        components.weekdayOrdinal = n
        return calendar.date(from: components).map(key)
    }

    /// "The last Monday in May." Expressed as an ordinal from the end, which
    /// `DateComponents` supports directly and which stays correct in the years
    /// when May has five Mondays.
    static func lastWeekday(_ weekday: Weekday, month: Int, year: Int) -> String? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.weekday = weekday.rawValue
        components.weekdayOrdinal = -1
        return calendar.date(from: components).map(key)
    }

    /// Easter Sunday, by the anonymous Gregorian computus.
    ///
    /// Worth the twenty lines rather than a table of dates: a table has to be
    /// extended by somebody who remembers it exists, and this is correct for
    /// every year it will ever be asked about.
    static func easterSunday(_ year: Int) -> String? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components).map(key)
    }
}
