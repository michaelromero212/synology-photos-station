import SwiftUI

#if os(iOS)
/// Where the bar sits and how much room it needs, for everything that has to
/// keep clear of it.
///
/// Measured off Photos on the same phone rather than chosen. Every number came
/// from counting pixels in a screenshot on a 402-point screen, which is worth
/// saying because several of them are not the round numbers anyone would have
/// guessed: the pill and the circle are both sixty-two points tall, and the bar
/// clears the leading edge, the trailing edge and the bottom of the screen by
/// twenty-one points each — *inside* the thirty-four point safe area, over the
/// home indicator's margin, which is exactly where Photos puts it.
///
/// Out here rather than nested in the bar because the bar is generic, and a
/// generic type cannot hold stored statics.
enum FloatingTabBarMetrics {
    /// Pill and circle: the same height, so they read as one row.
    static let height: CGFloat = 62
    /// Glass between the pill's edge and an item's box.
    static let pillPadding: CGFloat = 4
    /// One item at full size. It gives way on a narrower screen — see the note
    /// on `FloatingTabBar.body`.
    static let itemWidth: CGFloat = 91
    /// Between the pill and the circle.
    static let gap: CGFloat = 17
    static let sideInset: CGFloat = 21
    /// From the bottom of the *screen*, not of the safe area.
    static let bottomInset: CGFloat = 21
    /// Both glyphs, the tabs' and the magnifier's.
    static let glyph: CGFloat = 22
    /// Tall enough for the tallest symbol in the bar, so that a short one — the
    /// ellipsis — does not pull its own label up level with the icons beside it.
    static let glyphBox: CGFloat = 26
    static let label: CGFloat = 10

    /// From the bottom of the screen to where a screen's content should stop:
    /// over the bar, with a row's worth of air above it.
    static let clearance = bottomInset + height + 8

    /// What a screen has to add to the safe area it already has.
    ///
    /// The bottom safe area is the home indicator's margin, which the content is
    /// already being kept out of; the bar needs the rest. Asked of the window
    /// rather than of a `GeometryReader` for the reason `WindowMetrics` gives at
    /// length — a reader answers about its own region, and answers zero during
    /// the first layout pass on real hardware.
    @MainActor static var contentInset: CGFloat {
        max(0, clearance - WindowMetrics.bottomInset)
    }
}

/// What is on screen that the bar has to get out of the way of.
///
/// Two things put a bar of their own along the bottom of the screen. Selecting
/// in a grid does — Share, Add to Album, Delete — and so does the photo viewer,
/// with Share, Favorite, Info and Delete. Drawn in the same strip as this one,
/// either pair was illegible, and the viewer's buttons couldn't be pressed at
/// all. Two bars competing for one strip is not a stacking problem to be spaced
/// out of; only one of them is the answer to "what do I do now", and while you
/// are choosing photographs or looking at one it is not this one.
///
/// A singleton because the ends are far apart and cannot be wired together
/// directly: the selection lives in a `TimelineView`'s `@State`, the viewer is
/// pushed inside a tab's navigation stack, and the bar is an overlay on the
/// `TabView` well above both — with a tab and a navigation stack in between,
/// neither of which carries a preference up reliably.
@Observable
@MainActor
final class GridChrome {
    static let shared = GridChrome()
    var isSelecting = false

    /// The photo viewers on screen, each by a token of its own.
    ///
    /// A set rather than a flag, so that one viewer leaving can never bring the
    /// bar back over another still open — the search sheet can hold a viewer of
    /// its own — and a viewer that reports twice counts once.
    private(set) var openViewers: Set<UUID> = []

    func viewerOpened(_ token: UUID) { openViewers.insert(token) }
    func viewerClosed(_ token: UUID) { openViewers.remove(token) }

    /// Whether the bar should be out of the way.
    var hidesTabBar: Bool { isSelecting || !openViewers.isEmpty }
}

/// The bar along the bottom: three places in a pill, and search on its own.
///
/// Drawn here rather than by the system, which is a decision worth the cost of
/// explaining. A tab declared with `role: .search` is supposed to be pulled out
/// of the bar and drawn as a separate circle, and on a simulator running iOS 26
/// built with Xcode 27 it is. On his iPhone, same source, same OS family, the
/// same declaration renders as a fourth item inside the pill — almost certainly
/// because iOS gives an app the tab bar appearance of the SDK its binary was
/// linked against, and a rebuild is not something a photo library should depend
/// on to look right.
///
/// Hand-rolling it removes that dependency entirely: the bar is the same
/// wherever it runs, and it is something that can be checked on a simulator and
/// trusted on a phone. It also fixes a shape the system would not give us — with
/// the search tab removed, the system centers a three-item pill and leaves about
/// sixty-nine points beside it, which a sixty-two point circle cannot sit in
/// without touching. Leading-aligned, the pill and the circle both have room.
///
/// The cost is real and worth naming: no system search-field transformation on
/// 26, and no tab-bar minimize behavior. Neither was happening on his device
/// anyway, and the minimize behavior is one this app already turns off — it
/// resizes the scroll view's safe area on every toggle and feeds a layout storm.
/// See `ScrollProgress`.
struct FloatingTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let symbol: String
        var id: Tab { tab }
    }

    let items: [Item]
    @Binding var selection: Tab
    let onSearch: () -> Void

    private typealias Metrics = FloatingTabBarMetrics

    var body: some View {
        // Sized by the stack rather than by a `Spacer`, so the arithmetic is
        // decided rather than discovered. The circle is rigid and the pill is
        // not, so the circle is served first and the pill is handed whatever is
        // left up to its full width: on a 402-point screen that is exactly its
        // full width, and on a 375-point one the three items quietly give up
        // nine points each rather than shouldering the search button off the end
        // of the screen.
        HStack(spacing: Metrics.gap) {
            pill.frame(maxWidth: fullPillWidth)
            search
        }
        .padding(.horizontal, Metrics.sideInset)
        // Measured from the bottom of the display, where Photos measures from,
        // which on a phone with a home indicator is *below* where an overlay is
        // put by default — hence a negative number on those phones and a
        // positive one on the phones without an indicator. `ignoresSafeArea`
        // was the obvious move and does nothing here: by the time an overlay's
        // content is laid out the inset has already been applied to it, and
        // declining it after the fact declines nothing.
        //
        // This moves the *bar*. What keeps photographs from coming to rest
        // underneath it is `Metrics.contentInset`, applied once per screen.
        .padding(.bottom, Metrics.bottomInset - WindowMetrics.bottomInset)
    }

    private var fullPillWidth: CGFloat {
        CGFloat(items.count) * Metrics.itemWidth + Metrics.pillPadding * 2
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    // A second tap on the tab you are already on is not a
                    // change, and treating it as one re-runs every `.task`
                    // keyed on the selection.
                    guard selection != item.tab else { return }
                    selection = item.tab
                } label: {
                    label(for: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tab ? [.isSelected] : [])
            }
        }
        .padding(Metrics.pillPadding)
        .glassCapsule(interactive: false, fallback: .regularMaterial)
    }

    private func label(for item: Item) -> some View {
        VStack(spacing: 2) {
            Image(systemName: item.symbol)
                .font(.system(size: Metrics.glyph, weight: .regular))
                // A fixed box, so the three labels share a baseline. Without it
                // the stack centers each item on its own glyph and "More" — an
                // ellipsis a third the height of a photograph icon — rides up
                // level with its neighbours' pictures.
                .frame(height: Metrics.glyphBox)
            Text(item.title)
                .font(.system(size: Metrics.label, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(selection == item.tab ? Color.accentColor : Color.primary)
        .frame(maxWidth: Metrics.itemWidth)
        .frame(height: Metrics.height - Metrics.pillPadding * 2)
        // The selected item gets a lozenge rather than only a color, which is
        // what makes the current tab findable at a glance over a bright photo
        // — color alone disappears against a red sunset.
        .background {
            if selection == item.tab {
                Capsule().fill(.primary.opacity(0.12))
            }
        }
        .contentShape(Capsule())
    }

    private var search: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.glyph, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: Metrics.height, height: Metrics.height)
                .glassCircle(interactive: false, fallback: .regularMaterial)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
    }
}
#endif

extension View {
    /// Keeps a screen's content clear of the floating bar.
    ///
    /// A hidden system bar takes its inset with it, so without this every screen
    /// comes to rest with its last row underneath the glass: the bottom of the
    /// library, the last row of a list, the backup banner.
    ///
    /// Applied *inside* a screen's `NavigationStack` rather than to the tab that
    /// holds it, which is where it went first and did nothing — measured twice,
    /// once as `safeAreaPadding` and once as this, with the More list still
    /// running off the bottom of the display underneath the bar both times. A
    /// stack re-establishes the safe area for the screens it shows, so anything
    /// set outside one never reaches them.
    ///
    /// A constant, and that is the safety argument. What stormed this app's
    /// layout twice was an inset that *changed* as you scrolled: each change
    /// resized the scroll view, which re-realized rows, which resized it again.
    /// This one is the same on every frame, so there is no loop to enter.
    ///
    /// `when` is for the handful of screens that are shown both ways — pushed
    /// under the bar from one place and presented as a sheet from another, where
    /// there is no bar and this would be a gap at the bottom of a card.
    ///
    /// The library's own grid takes the same measurement as a content margin
    /// instead, beside the one it already uses at the top — it is the one screen
    /// with a hand-built top inset to sit beside, and keeping both ends of it in
    /// one place is worth more there than using the same modifier as everywhere
    /// else. See `TimelineView`.
    ///
    /// Nothing outside iOS: a Mac has a sidebar and a television keeps the
    /// system's own bar.
    /// Tells the floating bar to step aside while this screen is selecting.
    ///
    /// Three moments rather than one, because a selection can leave the screen
    /// without ending: `onAppear` covers arriving at a grid that is *still*
    /// selecting after a tab switch, `onChange` the selection starting and
    /// ending under your finger, and `onDisappear` backing out of a shared album
    /// mid-selection — which would otherwise leave the bar hidden on a screen
    /// with nothing to replace it.
    @ViewBuilder
    func floatingTabBarHidden(whileSelecting selecting: Bool) -> some View {
        #if os(iOS)
        onAppear { GridChrome.shared.isSelecting = selecting }
            .onChange(of: selecting) { _, active in
                GridChrome.shared.isSelecting = active
            }
            .onDisappear { GridChrome.shared.isSelecting = false }
        #else
        self
        #endif
    }

    @ViewBuilder
    func floatingTabBarClearance(when apply: Bool = true) -> some View {
        #if os(iOS)
        safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing to see and nothing to touch: it exists to take up room.
            // Left hit-testable it would swallow taps meant for the photograph
            // passing behind the bar.
            Color.clear
                .frame(height: apply ? FloatingTabBarMetrics.contentInset : 0)
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}
