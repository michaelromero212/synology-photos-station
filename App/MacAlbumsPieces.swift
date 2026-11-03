#if os(macOS)
import SwiftUI

// The parts the Mac's Albums page is built from, drawn the way Photos draws
// its Collections in a window: bold section titles that fold away, square
// cards with their names on the picture, and compact rows with counts. See
// `AlbumsView.macPage`.

/// How cards sit across a window: about `basis` wide, as many as fit between
/// the margins, sized to fill the row exactly — so every section's cards, and
/// every screen's, line up in the same columns. Photos fits seven across a
/// large window.
struct MacCardLayout {
    static let margin: CGFloat = 40
    static let gap: CGFloat = 20
    static let basis: CGFloat = 200

    let across: Int
    let side: CGFloat

    init(width: CGFloat) {
        let usable = max(width - Self.margin * 2, 1)
        across = max(2, Int((usable + Self.gap) / (Self.basis + Self.gap)))
        side = floor((usable - Self.gap * CGFloat(across - 1)) / CGFloat(across))
    }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(side), spacing: Self.gap, alignment: .topLeading),
            count: across
        )
    }
}

/// "1 item", "2,551 items".
func macItems(_ count: Int) -> String {
    "\(count.formatted()) item\(count == 1 ? "" : "s")"
}

/// A section's title line.
///
/// A chevron after the title when the title opens everything in the section,
/// as Photos' "Pinned ›" and "Media Types ›" do, and a round button at the far
/// end that folds the section away and brings it back.
struct MacSectionHeader: View {
    let title: String
    /// A line under the title saying who can see what's in it.
    var note: String?
    let isCollapsed: Bool
    /// Where the title leads, when it leads anywhere.
    var destination: (() -> AnyView)?
    let onToggle: () -> Void

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
                    .help("Show All \(title)")
                } else {
                    heading(chevron: false)
                }
                if let note, !isCollapsed {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
            .accessibilityLabel(isCollapsed ? "Show \(title)" : "Hide \(title)")
        }
    }

    private func heading(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .tracking(-0.3)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

/// A square card with its name on the picture: an album, a trip, a pinned
/// collection.
///
/// The name sits on the photograph over a low dark ramp, as on Photos' cards,
/// rather than under it — so a row of them reads as a row of pictures, and
/// every card on the page is the same shape whatever it holds.
struct MacCollectionTile<Cover: View>: View {
    let title: String
    /// The line under the name: a count, dates, who it's shared with.
    var detail: String?
    let side: CGFloat
    /// A small mark in the top corner: a heart on Favorites, two people on
    /// anything shared.
    var badge: String?
    @ViewBuilder let cover: () -> Cover

    @State private var isHovering = false

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        cover()
            .frame(width: side, height: side)
            .overlay(alignment: .bottomLeading) {
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
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(11)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .padding(10)
                }
            }
            .clipShape(Self.shape)
            // A hairline, so a dark photograph still has an edge against the
            // page, and a lift under the pointer to say it opens.
            .overlay {
                Self.shape.strokeBorder(.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 0.5)
            }
            .brightness(isHovering ? 0.04 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(Self.shape)
            .accessibilityElement(children: .combine)
    }
}

/// A card for something that has no photograph of its own — Places, Recently
/// Deleted: its symbol on a tinted ground.
struct MacSymbolCover: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: proxy.size.width * 0.2, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(y: -proxy.size.height * 0.06)
                }
        }
    }
}

/// A section with nothing in it yet, said the way Photos says it: what will
/// be here, and the way to start it when there is one.
struct MacEmptySection: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 28)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// One line under Media Types or Utilities: a symbol, a name, and how many.
struct MacUtilityRow: View {
    let title: String
    let symbol: String
    var count: Int?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let count {
                Text(count.formatted())
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.1 : 0.06))
        )
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
