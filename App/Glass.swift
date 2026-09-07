import SwiftUI

/// Liquid Glass, with a floor under it.
///
/// The SDK is iOS 26 but the deployment target is 17, so every glass call has to
/// be gated. The fallback is deliberately not "nothing": glass *replaces* the
/// material these controls already used rather than adding to it, so a control
/// that reads perfectly on 26 would become white text floating on a photo on 17.
/// Every helper here has a material underneath it for exactly that reason.
///
/// Kept as one file rather than sprinkled `#available` checks: when the
/// deployment target eventually moves to 26, the fallbacks come out of one place
/// instead of a dozen call sites.

// `#if compiler(...)` and not `#if available`: availability gates *runtime*,
// but `Glass` doesn't exist in the iOS 18 SDK at all, so an older toolchain
// can't even parse the reference. CI builds on Xcode 16 and broke on exactly
// this — a project that merely *offers* iOS 26 polish should still compile
// without the iOS 26 SDK, and fall back to the material underneath.
#if compiler(>=6.2)
@available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
private func frameStationGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    // `interactive` is what makes a glass control flex and highlight under a
    // finger. It's a touch affordance, so it's iOS-only on purpose.
    #if os(iOS)
    if interactive { glass = glass.interactive() }
    #endif
    return glass
}
#endif

extension View {
    /// Glass behind this view, clipped to `shape`.
    ///
    /// `fallback` is the pre-26 material. Callers pass `.regularMaterial` for
    /// chrome that sits over the app's own background and `.ultraThinMaterial`
    /// for chrome floating over a photo, where the photo should still read
    /// through it.
    @ViewBuilder
    func glassBackground(
        in shape: some Shape,
        tint: Color? = nil,
        interactive: Bool = true,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            self.glassEffect(
                frameStationGlass(tint: tint, interactive: interactive), in: shape
            )
        } else {
            self.background(fallback, in: shape)
        }
        #else
        self.background(fallback, in: shape)
        #endif
    }

    /// The common case: a capsule of glass, for bars and pills.
    func glassCapsule(
        tint: Color? = nil,
        interactive: Bool = true,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        glassBackground(
            in: Capsule(), tint: tint, interactive: interactive, fallback: fallback
        )
    }

    /// A single round control, the shape the photo viewer's buttons take.
    func glassCircle(
        tint: Color? = nil,
        interactive: Bool = true,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        glassBackground(
            in: Circle(), tint: tint, interactive: interactive, fallback: fallback
        )
    }

    /// The tab bar the library is meant to show through.
    ///
    /// Nothing to do on 26: the system already floats a Liquid Glass bar down
    /// there, and overriding its background is how you swap glass for a flat
    /// material. What made ours read as a solid slab was never the bar — it was
    /// that nothing was passing behind it to be seen through. See the grid's
    /// top-edge clip.
    ///
    /// Below 26 the bar is opaque enough to cut the grid off, so it takes a
    /// material instead. `.thin` rather than the `.ultraThin` the floating
    /// chrome uses: those are pills carrying one or two glyphs, and this one
    /// carries four labels that have to stay readable over a bright photo.
    ///
    /// iOS only — macOS has no tab bar to place this on.
    @ViewBuilder
    func glassTabBar() -> some View {
        #if os(iOS)
        // `#if compiler(>=6.2)` guards the iOS 26 SDK symbol the same way
        // `GlassGroup` does below: `tabBarMinimizeBehavior` doesn't exist in
        // older SDKs, and `if #available` is only a *runtime* gate — the symbol
        // still has to resolve at compile time. CI builds on Xcode 16.4 (iOS
        // 18.5 SDK), so without this the App target fails to compile there even
        // though a local iOS 26 toolchain is fine.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // The tab bar recedes as you scroll down into the grid and swoops
            // back the moment you scroll up — Apple's own gesture-tracked
            // minimize. It replaced a custom offset toggle that flipped the
            // bar's visibility mid-scroll; toggling `.tabBar` visibility resizes
            // the scroll view's safe area, so the bar reappearing at the bottom
            // bounce reflowed the grid and made the end of the library "trip".
            // The system owns the show/hide here now — see TimelineView's
            // `tabBarVisibility`, which steps aside on 26.
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self.toolbarBackground(.thinMaterial, for: .tabBar)
        }
        #else
        // Pre-26 toolchain (e.g. CI on Xcode 16.4): the material tab bar, which
        // is what the app shipped before the native minimize existed.
        self.toolbarBackground(.thinMaterial, for: .tabBar)
        #endif
        #else
        self
        #endif
    }
}

/// Groups glass siblings so the system can blend and morph them together.
///
/// Two `.glassEffect()` views sitting next to each other each sample the
/// background on their own and the seam between them shows. Inside a container
/// they're rendered as one piece of glass, which is what makes a row of buttons
/// read as a single control rather than a row of separate lozenges.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
