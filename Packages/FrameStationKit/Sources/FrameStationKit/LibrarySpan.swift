import Foundation

/// The library's true shape, so the scrubber need not ask the scroll view how
/// tall the content is.
///
/// It cannot ask, and that is the whole reason this exists. A `LazyVStack`
/// guesses at the sections it has not built, and measured on a real library the
/// guess came out at seven times the truth and never settled — so a thumb
/// positioned by `offset / contentHeight` lurched whenever a guess collapsed,
/// and rested a third of the way down a track at the end of the library.
///
/// The manifest knows better than the scroll view ever will. It carries every
/// day and its count before a single photograph loads, and on a square grid a
/// day's height follows from its count exactly. So the heights come from there
/// and the scroll view is asked only where it is, never how big it is.
public struct LibrarySpan: Equatable {
    /// Height of the whole library, in points.
    public var total: Double
    /// Where each day begins, and how tall it is.
    public var start: [String: Double]
    public var height: [String: Double]
    /// In order, so a point in the library can be turned back into a day.
    public var order: [String] = []
    /// What a day's heading costs above its first row, so the rows themselves
    /// can be located inside the day.
    public var header: Double = 0

    public init(
        total: Double,
        start: [String: Double],
        height: [String: Double],
        order: [String] = [],
        header: Double = 0
    ) {
        self.total = total
        self.start = start
        self.height = height
        self.order = order
        self.header = header
    }

    public static let empty = LibrarySpan(total: 0, start: [:], height: [:])

    /// Where to send the grid, and what to call the place.
    public struct Target: Equatable {
        /// The day the thumb is over: what the pill says, and what gets fetched.
        public let day: String
        /// The day whose rows the scroll is measured against — usually but not
        /// always the same one. Nil when no day's rows can reach the wanted
        /// point, and the grid should go to the day's heading instead.
        public let rows: String?
        /// Where in those rows to aim, 0…1.
        public let unit: Double
        /// The same place as a plain distance from the top of the library.
        ///
        /// What a grid that can be scrolled to an exact point uses instead of
        /// `rows` and `unit` — see `TimelineCollection`. Those two exist because
        /// a SwiftUI scroll view can only be sent to a *view*; a collection view
        /// knows where everything is and can simply be told how far to go.
        public let offset: Double
    }

    /// Where the grid should go for a given point down the track.
    ///
    /// Two things are being worked out here, and they are easier to follow
    /// apart.
    ///
    /// **Which day.** By *height*, which is the correction that matters. The
    /// obvious reading of a scrollbar fraction is a fraction of the photographs,
    /// and `buckets.bucket(atFraction:)` still does that — but a scrollbar does
    /// not travel in photographs. A day of one photograph is a heading and one
    /// row; a day of nine is a heading and three. So the same fraction of the
    /// library by count and by height name different months, and the pill was
    /// naming one while the grid went to the other. The travel is the library
    /// less one screen, matching `trueFraction`: at the bottom of the track the
    /// last screen should be *on* screen, not a screen below it.
    ///
    /// **Where inside it.** `scrollTo(_:anchor:)` aligns the same relative point
    /// in a target view and in the viewport, so aiming at a day's *rows* with an
    /// anchor of `u` comes to rest at `u × (day − screen)` past their top. For a
    /// day taller than the screen that sweeps the whole day continuously, which
    /// is the case that used to lurch worst — a holiday of three hundred
    /// photographs was eight screens crossed in one step.
    ///
    /// A day *shorter* than the screen can only be reached at its top: the
    /// arithmetic runs backwards there, and `u` sweeps from a screen above the
    /// day down to it rather than through it. That is what the loop is for.
    /// Rather than give up and land on the day's heading, it asks the next few
    /// days whether the wanted point falls in *their* reach — and for a run of
    /// small days it does, because a day that starts a little below the target
    /// can be pulled up to sit a little below the top of the screen. The result
    /// is that the grid lands where the thumb points in both cases, and the
    /// heading fallback is left for the ends of the library.
    ///
    /// Anchoring on a *day* rather than on the whole library is the point of
    /// all this, and it was arrived at the hard way. Aiming at the entire stack
    /// with a fraction is the obvious move and does not work: a lazy stack does
    /// not know how tall it is, only how tall the handful of days it has built
    /// are, so the same fraction landed in a different place depending on where
    /// you had been — measured, asking for a tenth of the library and arriving
    /// at 0.27. A single day's height is known exactly the moment that day is
    /// built, and `scrollTo` builds what it is sent to.
    ///
    /// Linear, and that is not a shortcut: days are few enough that a scan is
    /// nothing next to the work of drawing a frame, and the alternative — a
    /// parallel array of running totals — is a second copy of `start` that can
    /// disagree with it.
    public func target(atFraction fraction: Double, viewport: Double) -> Target? {
        guard total > 0, !order.isEmpty, viewport > 0 else { return nil }
        let offset = min(max(fraction, 0), 1) * max(total - viewport, 0)

        var index = 0
        for (i, key) in order.enumerated() {
            guard let begin = start[key], begin <= offset else { break }
            index = i
        }
        let day = order[index]

        // Eight is enough to cross a run of one-photograph days and cheap
        // enough to do on every frame of a drag. Past that the library is
        // sparse enough that landing on a heading is no worse.
        for next in index..<min(index + 8, order.count) {
            let key = order[next]
            guard let begin = start[key], let span = height[key] else { continue }
            let room = span - header - viewport
            guard abs(room) > 1 else { continue }
            let unit = (offset - begin - header) / room
            if unit >= 0, unit <= 1 {
                return Target(day: day, rows: key, unit: unit, offset: offset)
            }
        }
        return Target(day: day, rows: nil, unit: 0, offset: offset)
    }
}

