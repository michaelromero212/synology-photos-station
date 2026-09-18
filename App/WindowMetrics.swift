#if os(iOS)
import UIKit

/// The window's own safe-area insets, remembered.
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
///
/// Main-actor isolated, and not only to satisfy the compiler: the cache is
/// mutable static state, every caller is a view body or a `task` on the main
/// actor, and an unisolated cache shared across threads is a race waiting for a
/// reason.
@MainActor
enum WindowMetrics {
    private static var rememberedTop: CGFloat = 0
    private static var rememberedBottom: CGFloat = 0

    /// The live value when there is one, the last good one otherwise.
    static var topInset: CGFloat {
        if let live = measure()?.top, live > 0 {
            rememberedTop = live
            return live
        }
        return rememberedTop
    }

    /// The home indicator's margin, which the floating tab bar is placed
    /// relative to and which every screen's content is already kept out of.
    ///
    /// Same caching as the top, with one difference that matters: zero is a
    /// *correct* answer here, on any phone with a home button. So there is no
    /// way to tell "not measured yet" from "genuinely nothing", and this simply
    /// answers what it last read. The cost of being wrong is small in a way the
    /// top's was not — the bar lands 34pt high for one layout pass rather than
    /// the entire library jumping.
    static var bottomInset: CGFloat {
        if let live = measure()?.bottom {
            rememberedBottom = live
            return live
        }
        return rememberedBottom
    }

    /// Reads and caches. Called before anything lays out, so the grid's first
    /// pass has a real number instead of a zero.
    ///
    /// Says so in the log when it comes up empty, because a silent zero here is
    /// a 62pt jolt at launch and the first attempt at this failed in exactly
    /// that way — looking correct locally while answering nil on the device.
    static func seed() {
        // Read for its side effect: both insets are cached here so the first
        // layout pass has real numbers, and the bottom one has no zero-means-
        // missing test of its own to fall back on.
        _ = bottomInset
        if topInset == 0 {
            LayoutWatch.shared.note("window inset still unavailable at seed")
        }
    }

    /// Permissive on purpose, and the previous version's fussiness is why this
    /// needed a second attempt.
    ///
    /// It asked for a scene that was `.foregroundActive` and then for that
    /// scene's `keyWindow`. During launch a scene is `.foregroundInactive` and
    /// has no key window yet — so on a real device it answered nil for the whole
    /// of the period that matters, and the grid laid out against a zero. A
    /// simulator reaches `.foregroundActive` sooner, which is the entire reason
    /// this looked fixed here and was not fixed on his phone.
    ///
    /// Any window of any window scene knows the insets. They are a property of
    /// the screen, not of who is focused.
    private static func measure() -> UIEdgeInsets? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        // The key window when there is one, because on iPad a detached or
        // secondary window can be a different size; otherwise anything, because
        // a wrong-by-a-hair inset beats a zero by a mile.
        if let key = windows.first(where: \.isKeyWindow) {
            return key.safeAreaInsets
        }
        return windows.first?.safeAreaInsets
    }
}
#endif
