import SwiftUI

// The pieces the Albums page, and the screens it opens, are built from on
// every platform, drawn the way Photos draws its Collections: a section's
// title line, which folds the section away; a card with its name on the
// picture; a compact row with a count; and what an empty section says.
//
// One set, so an iPhone, an iPad, a Mac and a television show the same
// sections under the same titles with the same cards. What differs is how
// many fit across, how big the type is when it's read from across a room,
// and whether a section folds away. These were the Mac's alone, and the
// phone drew the same page as a column of list rows. See `AlbumsView`.

// MARK: - Layout

/// How cards sit across a screen `width` points wide.
///
/// A phone fits whole cards between its margins, three small or two medium,
/// and a row that scrolls sideways shows the next card peeking in at the
/// edge, which says there is more to swipe to. Anything wider fits as many
/// whole cards as there is room for at about `basis` points each, sized to
/// fill the row exactly, so every section's cards line up in the same
/// columns.
struct CollectionsLayout {
    /// The two sizes of card. A Mac has one size, as Photos does there.
    enum Size {
        /// Pinned and People: three across a phone.
        case small
        /// Albums, trips, occasions and the years: two across a phone.
        case medium
    }

    let width: CGFloat
    /// From the screen's edge to the first card, and from the last card to
    /// the other edge.
    let margin: CGFloat
    /// Between two cards, across and down.
    let gap: CGFloat
    /// Whether a section's row scrolls sideways (touch and focus), rather
    /// than showing one row's worth with the rest behind its title (a
    /// pointer, on a Mac).
    let scrollsSideways: Bool
    /// A phone's width: cards sized by how many go across, not by `basis`.
    let isCompact: Bool

    init(width: CGFloat) {
        self.width = width
        #if os(macOS)
        margin = 40
        gap = 20
        scrollsSideways = false
        isCompact = false
        #elseif os(tvOS)
        // The television's safe area already holds everything in from the
        // edge of the screen.
        margin = 14
        gap = 40
        scrollsSideways = true
        isCompact = false
        #else
        isCompact = width < 600
        margin = isCompact ? 20 : 32
        gap = isCompact ? 10 : 16
        scrollsSideways = true
        #endif
    }

    /// How many whole cards of `size` fit across.
    func across(_ size: Size) -> Int {
        if isCompact { return size == .small ? 3 : 2 }
        let usable = max(width - margin * 2, 1)
        let basis = Self.basis(size)
        return max(2, Int((usable + gap) / (basis + gap)))
    }

    /// A card's side, so `across` of them fill the row between the margins.
    func side(_ size: Size) -> CGFloat {
        let count = CGFloat(across(size))
        let usable = max(width - margin * 2, 1)
        return max(1, floor((usable - gap * (count - 1)) / count))
    }

    /// Fixed columns of `size` cards, for a grid of every one of them: the
    /// albums, and everything behind a section's title.
    func columns(_ size: Size) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(side(size)), spacing: gap, alignment: .topLeading),
            count: across(size)
        )
    }

    /// About how wide a card is on a screen with room to spare.
    private static func basis(_ size: Size) -> CGFloat {
        #if os(macOS)
        return 200
        #elseif os(tvOS)
        return size == .small ? 240 : 340
        #else
        return size == .small ? 120 : 200
        #endif
    }

    /// A card along the top of the page: square on a phone, as Photos draws
    /// its memories there, and wider than tall anywhere with room for it.
    var memorySize: CGSize {
        #if os(macOS)
        // Full width at five by four was a card taller than the window on a
        // large display.
        return CGSize(width: 380, height: 304)
        #elseif os(tvOS)
        return CGSize(width: 640, height: 400)
        #else
        if isCompact {
            // Two small cards and the gap between them, so the next card
            // peeks in at the edge.
            let side = self.side(.small) * 2 + gap
            return CGSize(width: side, height: side)
        }
        let side = min(400, max(300, floor((width - margin * 2) * 0.34)))
        return CGSize(width: side, height: floor(side * 0.8))
        #endif
    }

    /// The columns a section's compact rows sit in, where they fit across:
    /// as many as fit. A phone has no room for two whole ones side by side;
    /// see `rowWidth`.
    var rowColumns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 24, alignment: .leading)]
        #elseif os(tvOS)
        return [GridItem(.adaptive(minimum: 480, maximum: 600), spacing: gap, alignment: .leading)]
        #else
        return [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: gap, alignment: .leading)]
        #endif
    }

    /// On a phone, how wide each compact row is. Two side by side cut
    /// "Recently Deleted" down to "Recently…", so a phone does what Photos
    /// does there: rows wider than half the screen, stacked a few deep in
    /// columns that scroll sideways, the next column peeking in at the edge.
    /// Nil anywhere wider, where they sit in `rowColumns`.
    var rowWidth: CGFloat? {
        isCompact ? floor(width * 0.58) : nil
    }

    /// How deep a phone stacks `count` compact rows: two deep for a few, so a
    /// second column shows there's more, and three for more than four.
    func rowStack(_ count: Int) -> [GridItem] {
        let deep = count <= 2 ? max(count, 1) : (count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.fixed(CollectionsPill.height), spacing: rowSpacing), count: deep)
    }

    /// Between two lines of compact rows.
    var rowSpacing: CGFloat {
        #if os(macOS)
        return 9
        #elseif os(tvOS)
        return 24
        #else
        return 8
        #endif
    }

    /// Between one section and the next.
    static var sectionSpacing: CGFloat {
        #if os(macOS)
        return 36
        #elseif os(tvOS)
        return 60
        #else
        return 30
        #endif
    }

    /// Between a section's title and what's in it.
    static var headerSpacing: CGFloat {
        #if os(macOS)
        return 14
        #elseif os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    /// Every card's corners. The cards along the top have their own.
    static var cornerRadius: CGFloat {
        #if os(macOS)
        return 12
        #elseif os(tvOS)
        return 16
        #else
        return 14
        #endif
    }
}

/// "1 item", "2,551 items".
func itemsLine(_ count: Int) -> String {
    "\(count.formatted()) item\(count == 1 ? "" : "s")"
}

// MARK: - Section title

/// A section's title line.
///
/// A chevron after the title when the title opens everything in the section,
/// as Photos' "Pinned ›" and "Media Types ›" do, and a round button at the far
/// end that folds the section away and brings it back. A television's
/// sections don't fold: there's no button to aim the remote at, and nothing
/// to save room for on a screen that size.
struct CollectionsSectionHeader: View {
    let title: String
    /// A line under the title saying who can see what's in it.
    var note: String?
    /// Where the title leads, when it leads anywhere.
    var destination: (() -> AnyView)?
    var isCollapsed = false
    /// Folds the section away and back; nil where sections don't fold.
    var onToggle: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let destination {
                    NavigationLink {
                        destination()
                    } label: {
                        heading(chevron: true)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Show All \(title)")
                    #endif
                } else {
                    heading(chevron: false)
                }
                if let note, !isCollapsed {
                    Text(note)
                        .font(Self.noteFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Self.toggleGlyph, weight: .bold))
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: Self.toggleSize, height: Self.toggleSize)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
                #endif
                .accessibilityLabel(isCollapsed ? "Show \(title)" : "Hide \(title)")
            }
        }
    }

    private func heading(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(Self.titleFont)
                .tracking(-0.3)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(Self.chevronFont)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private static var titleFont: Font {
        #if os(macOS)
        return .system(size: 19, weight: .bold)
        #elseif os(tvOS)
        return .title3.weight(.bold)
        #else
        return .title2.weight(.bold)
        #endif
    }

    private static var chevronFont: Font {
        #if os(macOS)
        return .system(size: 14, weight: .bold)
        #elseif os(tvOS)
        return .headline.weight(.bold)
        #else
        return .title3.weight(.bold)
        #endif
    }

    private static var noteFont: Font {
        #if os(macOS)
        return .callout
        #elseif os(tvOS)
        return .callout
        #else
        return .footnote
        #endif
    }

    private static var toggleSize: CGFloat {
        #if os(macOS)
        return 24
        #else
        return 30
        #endif
    }

    private static var toggleGlyph: CGFloat {
        #if os(macOS)
        return 10
        #else
        return 13
        #endif
    }
}

// MARK: - Cards

/// A card with its name on the picture: an album, a trip, a pinned
/// collection.
///
/// The name sits on the photograph over a low dark ramp, as on Photos' cards,
/// rather than under it, so a row of them reads as a row of pictures and
/// every card on the page is the same shape whatever it holds.
struct CollectionTile<Cover: View>: View {
    let title: String
    /// The line under the name: a count, dates, who it's shared with.
    var detail: String?
    let width: CGFloat
    /// Square unless given.
    var height: CGFloat?
    /// A small mark in the top corner: a heart on Favorites, two people on
    /// anything shared.
    var badge: String?
    @ViewBuilder let cover: () -> Cover

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CollectionsLayout.cornerRadius, style: .continuous)
    }

    /// A phone's two-across cards have room for bigger type than its
    /// three-across ones.
    private var isLarge: Bool { width >= 150 }

    var body: some View {
        cover()
            .frame(width: width, height: height ?? width)
            .overlay(alignment: .bottomLeading) { label }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: badgeSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .padding(inset)
                }
            }
            .clipShape(shape)
            // A hairline, so a dark photograph still has an edge against the
            // page, and a lift under the pointer to say it opens.
            .overlay {
                shape.strokeBorder(.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 0.5)
            }
            #if !os(tvOS)
            .brightness(isHovering ? 0.04 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            #endif
            .contentShape(shape)
            .accessibilityElement(children: .combine)
    }

    private var label: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.72), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.3),
                    .init(color: .clear, location: 0.55),
                ],
                startPoint: .bottom, endPoint: .top
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail {
                    // Two lines on the bigger cards and a little smaller
                    // before it's cut off: a trip's dates ("October 31 –
                    // November 5, 2024") and where it was are wider than a
                    // phone's two-across card.
                    Text(detail)
                        .font(detailFont)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(isLarge ? 2 : 1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(inset)
            #if os(iOS)
            // The card doesn't grow with the type, so the type stops growing
            // before it no longer fits on the card.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            #endif
        }
    }

    private var titleFont: Font {
        #if os(macOS)
        return .system(size: 13, weight: .semibold)
        #elseif os(tvOS)
        return .callout.weight(.semibold)
        #else
        return isLarge ? .subheadline.weight(.semibold) : .footnote.weight(.semibold)
        #endif
    }

    private var detailFont: Font {
        #if os(macOS)
        return .system(size: 11)
        #elseif os(tvOS)
        return .caption
        #else
        return isLarge ? .caption : .caption2
        #endif
    }

    private var inset: CGFloat {
        #if os(macOS)
        return 11
        #elseif os(tvOS)
        return 18
        #else
        return isLarge ? 12 : 9
        #endif
    }

    private var badgeSize: CGFloat {
        #if os(tvOS)
        return 22
        #else
        return 12
        #endif
    }
}

/// A card for something that has no photograph of its own (Places, Recently
/// Deleted): its symbol on a tinted ground.
struct SymbolCover: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    // Above the middle, clear of a name on two lines at the
                    // bottom: "Recently Deleted" on a phone's small card ran
                    // into the symbol.
                    Image(systemName: symbol)
                        .font(.system(size: proxy.size.width * 0.18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(y: -proxy.size.height * 0.13)
                }
        }
    }
}

/// A row of cards that scrolls sideways from the page's margin, coming to
/// rest on a card's edge, the way Photos' rows do.
struct CollectionsShelf<Content: View>: View {
    let layout: CollectionsLayout
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: layout.gap) {
                content()
            }
            .scrollTargetLayout()
            #if os(tvOS)
            // Room for a focused card to grow.
            .padding(.vertical, 24)
            #endif
        }
        // A margin rather than padding: cards come to rest against it, not
        // against the edge of the screen.
        .contentMargins(.horizontal, layout.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .scrollClipDisabled()
        .padding(.vertical, -24)
        #endif
    }
}

// MARK: - Rows

/// One line under Media Types or Utilities: a symbol, a name, and how many.
struct CollectionsPill: View {
    let title: String
    let symbol: String
    var count: Int?

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(Self.iconFont)
                .foregroundStyle(.tint)
                .frame(width: Self.iconWidth)
            Text(title)
                .font(Self.titleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if let count {
                Text(count.formatted())
                    .font(Self.countFont)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Self.padding)
        .frame(height: Self.height)
        .background(shape.fill(Color.primary.opacity(isHovering ? 0.1 : 0.06)))
        #if !os(tvOS)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        #endif
        #if os(iOS)
        // One line in a row of fixed height: the type stops growing before it
        // no longer fits.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        #endif
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }

    /// Every compact row's height, so a phone's columns of them stack evenly.
    static var height: CGFloat {
        #if os(macOS)
        return 38
        #elseif os(tvOS)
        return 84
        #else
        return 46
        #endif
    }

    private static var radius: CGFloat {
        #if os(macOS)
        return 10
        #elseif os(tvOS)
        return 16
        #else
        return 13
        #endif
    }

    private static var padding: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 14
        #endif
    }

    private static var iconWidth: CGFloat {
        #if os(macOS)
        return 20
        #elseif os(tvOS)
        return 40
        #else
        return 24
        #endif
    }

    private static var iconFont: Font {
        #if os(macOS)
        return .system(size: 13)
        #else
        return .body
        #endif
    }

    private static var titleFont: Font {
        #if os(macOS)
        return .system(size: 13)
        #else
        return .body
        #endif
    }

    private static var countFont: Font {
        #if os(macOS)
        return .system(size: 13)
        #elseif os(tvOS)
        return .callout
        #else
        return .subheadline
        #endif
    }
}

// MARK: - Nothing here yet

/// A section with nothing in it yet, said the way Photos says it: what will
/// be here, and the way to start it where there is one.
struct CollectionsEmptyCard: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(Self.symbolFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Self.space)
                Text(title)
                    .font(Self.titleFont)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(Self.messageFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    #if !os(tvOS)
                    .controlSize(.small)
                    #endif
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private static var symbolFont: Font {
        #if os(macOS)
        return .system(size: 17)
        #else
        return .title2
        #endif
    }

    private static var titleFont: Font {
        #if os(macOS)
        return .system(size: 13, weight: .semibold)
        #elseif os(tvOS)
        return .headline
        #else
        return .body.weight(.semibold)
        #endif
    }

    private static var messageFont: Font {
        #if os(macOS)
        return .system(size: 12)
        #elseif os(tvOS)
        return .callout
        #else
        return .subheadline
        #endif
    }

    private static var space: CGFloat {
        #if os(macOS)
        return 28
        #elseif os(tvOS)
        return 40
        #else
        return 34
        #endif
    }

    private static var padding: CGFloat {
        #if os(tvOS)
        return 32
        #else
        return 18
        #endif
    }

    private static var minHeight: CGFloat {
        #if os(macOS)
        return 118
        #elseif os(tvOS)
        return 220
        #else
        return 150
        #endif
    }

    private static var radius: CGFloat {
        #if os(macOS)
        return 14
        #elseif os(tvOS)
        return 24
        #else
        return 22
        #endif
    }
}

// MARK: - Page edges

extension CollectionsLayout {
    /// Above the first section and below the last, on the Albums page and on
    /// every screen it opens.
    static var pagePadding: CGFloat {
        #if os(macOS)
        return 22
        #else
        return 16
        #endif
    }
}

// MARK: - Media type symbols

extension CollectionsPill {
    /// A media type's mark. The rows read as a list of kinds, so each needs a
    /// mark of its own: six identical rectangles would be a list you have to
    /// read every time.
    ///
    /// The same marks as the Mac's sidebar rows (`MacRootView.icon(for:)`).
    static func symbol(forMediaType key: String) -> String {
        switch key {
        case "video": return "video"
        case "live": return "livephoto"
        case "burst": return "square.stack.3d.down.right"
        case "screenshot": return "camera.viewfinder"
        case "screenRecording": return "record.circle"
        case "panorama": return "pano"
        case "slomo": return "slowmo"
        case "timelapse": return "timelapse"
        case "portrait": return "person.crop.square"
        case "cinematic": return "film"
        case "raw": return "camera.aperture"
        default: return "photo"
        }
    }
}
