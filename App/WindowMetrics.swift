#if os(iOS)
import UIKit

/// The window's own safe-area inset, remembered.
///
/// `keyWindow` is nil during the first layout pass on a real device, and the
/// obvious `?? 0` fallback is not harmless here: the grid feeds this into its
/// top content margin, so a zero meant the margin came up 54 instead of 116 and
/// corrected itself 80ms later — the whole library shifting down 62pt just
/// after launch. Caught in a layout log from his phone:
///
///     [0.01s] top inset 0 → 54
///     [0.09s] top inset 54 → 116
///
/// A simulator never showed it, because there the window exists by the time the
/// grid first asks.
///
/// So the value is seeded as early as the scene allows and remembered
/// afterwards. It is a device constant in portrait — which the iPhone is locked
/// to — and on iPad `seed()` runs again on every size change, so a rotation or a
/// Split View resize re-reads it rather than trusting a stale number.
enum WindowMetrics {
    private static var remembered: CGFloat = 0

    /// The live value when there is one, the last good one otherwise.
    static var topInset: CGFloat {
        if let live = measure(), live > 0 {
            remembered = live
            return live
        }
        return remembered
    }

    /// Reads and caches. Called before anything lays out, so the grid's first
    /// pass has a real number instead of a zero.
    static func seed() { _ = topInset }

    private static func measure() -> CGFloat? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.safeAreaInsets.top
    }
}
#endif
