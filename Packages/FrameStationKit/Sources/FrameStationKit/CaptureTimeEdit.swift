import FrameStationAPI
import Foundation

/// Works out what re-timing a selection actually means.
///
/// Synology's dialog asks for a "File Type" and then explains, in a paragraph,
/// that it will retain relative time intervals. The two things a person wants
/// are simpler than that wording: either these photos all happened at one
/// moment, or the camera's clock was wrong by a fixed amount and everything
/// should slide together. This is those two, named.
///
/// Pure arithmetic, and deliberately client-side. The server takes a list of
/// absolute timestamps, so the sheet can show precisely what it is about to
/// apply — and neither side has to reimplement the other's idea of "shift".
public enum CaptureTimeEdit {
    public enum Mode: String, CaseIterable, Sendable {
        /// Everything slides by the same amount, keeping the gaps between shots.
        /// The right answer for a camera set to the wrong time zone.
        case shift
        /// Everything lands on one timestamp. The right answer for a batch of
        /// scans that share a date and have no meaningful order.
        case setAll
    }

    /// The photo whose time the picker starts on, and the one a shift is
    /// measured from: the earliest in the selection.
    ///
    /// Earliest rather than "whichever was tapped first" so the same selection
    /// always produces the same edit, however it was assembled.
    public static func anchor(in items: [TimelineItem]) -> TimelineItem? {
        items.min { $0.capturedAt < $1.capturedAt }
    }

    /// - Parameter target: the time the anchor should end up at.
    public static func plan(
        items: [TimelineItem], mode: Mode, target: Date
    ) -> [EditCaptureTimeRequest.Item] {
        guard let anchor = anchor(in: items) else { return [] }

        switch mode {
        case .setAll:
            return items.map {
                EditCaptureTimeRequest.Item(assetID: $0.assetID, capturedAt: target)
            }
        case .shift:
            let delta = target.timeIntervalSince(anchor.capturedAt)
            return items.map {
                EditCaptureTimeRequest.Item(
                    assetID: $0.assetID,
                    capturedAt: $0.capturedAt.addingTimeInterval(delta)
                )
            }
        }
    }
}
