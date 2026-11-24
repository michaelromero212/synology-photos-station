import FrameStationAPI
import FrameStationKit
import SwiftUI

// Over the Years: what comes round every year, each with all its years. The
// server finds them (see `CollectionsResponse.traditions`); these draw the
// whole list and one tradition's years. Each year opens as every card on the
// Albums page does, so a year here is the same photos Holidays & Occasions
// opens.

/// Every tradition, the soonest to come around first: what the section's
/// title opens. The Albums page's cards, in its columns.
///
/// Read live from the page's store, like `CollectionListView`, so a date named
/// inside one of them has its name here too when you come back.
struct TraditionListView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore

    private var traditions: [Tradition] { store.page?.traditions ?? [] }

    var body: some View {
        GeometryReader { proxy in
            let layout = CollectionsLayout(width: proxy.size.width)
            let side = layout.side(.medium)
            ScrollView {
                LazyVGrid(columns: layout.columns(.medium), alignment: .leading, spacing: layout.gap) {
                    ForEach(traditions) { tradition in
                        NavigationLink {
                            TraditionView(session: session, space: space, store: store, tradition: tradition)
                        } label: {
                            TraditionTile(tradition: tradition, side: side, loader: session.loader)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, layout.margin)
                .padding(.vertical, CollectionsLayout.pagePadding)
            }
        }
        .navigationTitle("Over the Years")
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        // Its covers are the page's, and hold still with them. See
        // `CollectionsStore.take`.
        .holdsCovers(store)
    }
}

/// One tradition's years, newest first, each opening on its own photos.
///
/// Where the tradition is a date — one the library found, or one already
/// named — the toolbar offers to call it what it is, for every year at once.
/// A holiday or an event already has its name, so there it doesn't.
struct TraditionView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore
    /// As it was when it was opened.
    let tradition: Tradition

    @State private var naming: CollectionSummary?

    /// The page's own, so a name given here is the title here the moment the
    /// page has it. The one it was opened with otherwise, so a refresh that
    /// doesn't find it any more leaves the screen as it was rather than empty.
    private var shown: Tradition {
        store.page?.traditions?.first { $0.id == tradition.id } ?? tradition
    }

    var body: some View {
        let tradition = shown
        content(tradition)
            // Its years' covers are the page's, and hold still with them. See
            // `CollectionsStore.take`.
            .holdsCovers(store)
            .navigationTitle(tradition.title)
            // The floating tab bar is drawn over this — see `FloatingTabBar`.
            .floatingTabBarClearance()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(tvOS)
            .toolbar {
                if let card = tradition.naming {
                    ToolbarItem(placement: .primaryAction) {
                        // A word rather than a symbol: "Aa" alone in the bar
                        // didn't say what it was for.
                        Button(card.isNamed ? "Rename" : "Name") {
                            naming = card
                        }
                        .help(card.isNamed ? "Rename this day, every year" : "Name this day, every year")
                        .accessibilityLabel(card.isNamed ? "Rename This Day" : "Name This Day")
                    }
                }
            }
            .sheet(item: $naming) { card in
                NameOccasionSheet(
                    session: session, spaceID: space.id, collection: card, everyYear: true
                ) { changed in
                    naming = nil
                    // The server decides what the date ends up called, and a
                    // name for every year changes every year of it at once.
                    if changed { Task { await store.refresh() } }
                }
            }
            #endif
    }

    /// Its years as the Albums page's cards, in its columns, under the line
    /// that says how many and when.
    private func content(_ tradition: Tradition) -> some View {
        GeometryReader { proxy in
            let layout = CollectionsLayout(width: proxy.size.width)
            let side = layout.side(.medium)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = tradition.subtitle {
                        Text(subtitle)
                            .font(Self.subtitleFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: layout.columns(.medium), alignment: .leading, spacing: layout.gap) {
                        ForEach(tradition.years) { year in
                            NavigationLink {
                                CollectionDetailView(session: session, space: space, collection: year)
                            } label: {
                                CollectionTile(
                                    title: year.title, detail: year.subtitle ?? itemsLine(year.count),
                                    width: side
                                ) {
                                    CollectionCover(
                                        assetIDs: year.coverAssetIDs, loader: session.loader, size: 512
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, layout.margin)
                .padding(.vertical, CollectionsLayout.pagePadding)
            }
        }
    }

    private static var subtitleFont: Font {
        #if os(macOS)
        return .callout
        #else
        return .subheadline
        #endif
    }
}

/// A tradition as a card: its name, and how many years and when, on a photo
/// from one of them.
struct TraditionTile: View {
    let tradition: Tradition
    let side: CGFloat
    let loader: ThumbnailLoader?

    var body: some View {
        CollectionTile(
            title: tradition.title, detail: tradition.subtitle ?? itemsLine(tradition.count),
            width: side
        ) {
            CollectionCover(assetIDs: tradition.coverAssetIDs, loader: loader, size: 512)
        }
    }
}
