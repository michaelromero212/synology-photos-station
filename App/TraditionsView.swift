import FrameStationAPI
import FrameStationKit
import SwiftUI

// Over the Years: what comes round every year, each with all its years. The
// server finds them (see `CollectionsResponse.traditions`); these draw the
// whole list and one tradition's years. Each year opens as every card on the
// Albums page does, so a year here is the same photos Holidays & Occasions
// opens.

/// Every tradition, the soonest to come round first: what the section's See
/// All opens.
///
/// Read live from the page's store, like `CollectionListView`, so a date named
/// inside one of them has its name here too when you come back.
struct TraditionListView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore

    private var traditions: [Tradition] { store.page?.traditions ?? [] }

    var body: some View {
        #if os(macOS)
        // Photos' cards, as on the Albums page this opened from.
        GeometryReader { proxy in
            let layout = MacCardLayout(width: proxy.size.width)
            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MacCardLayout.gap) {
                    ForEach(traditions) { tradition in
                        NavigationLink {
                            TraditionView(session: session, space: space, store: store, tradition: tradition)
                        } label: {
                            TraditionTile(tradition: tradition, side: layout.side, loader: session.loader)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MacCardLayout.margin)
                .padding(.vertical, 22)
            }
        }
        .navigationTitle("Over the Years")
        #else
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(traditions) { tradition in
                    NavigationLink {
                        TraditionView(session: session, space: space, store: store, tradition: tradition)
                    } label: {
                        TraditionRow(tradition: tradition, loader: session.loader)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Over the Years")
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #endif
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

    @ViewBuilder
    private func content(_ tradition: Tradition) -> some View {
        #if os(macOS)
        GeometryReader { proxy in
            let layout = MacCardLayout(width: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = tradition.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MacCardLayout.gap) {
                        ForEach(tradition.years) { year in
                            NavigationLink {
                                CollectionDetailView(session: session, space: space, collection: year)
                            } label: {
                                MacCollectionTile(
                                    title: year.title, detail: year.subtitle ?? macItems(year.count),
                                    side: layout.side
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
                .padding(.horizontal, MacCardLayout.margin)
                .padding(.vertical, 22)
            }
        }
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let subtitle = tradition.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                ForEach(tradition.years) { year in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: year)
                    } label: {
                        CollectionRowCard(collection: year, loader: session.loader)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        #endif
    }
}

/// A tradition as a row on the phone's page: its cover, its name, how many
/// years, and how many photos across them.
struct TraditionRow: View {
    let tradition: Tradition
    let loader: ThumbnailLoader?

    var body: some View {
        CollectionRowCard(
            title: tradition.title, subtitle: tradition.subtitle, count: tradition.count,
            coverAssetIDs: tradition.coverAssetIDs, loader: loader
        )
    }
}

#if os(macOS)
/// A tradition as one of the Mac page's square cards.
struct TraditionTile: View {
    let tradition: Tradition
    let side: CGFloat
    let loader: ThumbnailLoader?

    var body: some View {
        MacCollectionTile(
            title: tradition.title, detail: tradition.subtitle ?? macItems(tradition.count), side: side
        ) {
            CollectionCover(assetIDs: tradition.coverAssetIDs, loader: loader, size: 512)
        }
    }
}
#endif
