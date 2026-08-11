import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Search, scoped to one space.
///
/// The screen is useful before anything is typed: it opens on the places this
/// library actually has photos from, commonest first, with counts. That is the
/// difference between a search box — which asks you to guess what the app
/// knows — and a way in. Typing filters the same list, and picking one shows
/// the photos.
///
/// One axis for now, deliberately. Place names are filled in at import for
/// every photo carrying GPS, so this works on day one across a whole library;
/// tags exist only where somebody typed one.
@MainActor
struct SearchView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var places: [PlaceSummary] = []
    @State private var query = ""
    @State private var selected: String?
    @State private var results: [TimelineItem] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var isLoadingPlaces = true
    @State private var isSearching = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    private let spacing: CGFloat = PhotoGridMetrics.spacing

    /// Always-visible on iOS: this screen exists to be searched, so a field
    /// that has to be scrolled into view would be hiding its own point. The
    /// drawer placement doesn't exist off iOS, where the system puts the field
    /// in the toolbar itself.
    static var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        return .navigationBarDrawer(displayMode: .always)
        #else
        return .automatic
        #endif
    }

    var body: some View {
        Group {
            if let selected {
                resultsGrid(for: selected)
            } else {
                placesList
            }
        }
        .navigationTitle(selected ?? "Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, placement: Self.searchPlacement, prompt: "Places")
        .onSubmit(of: .search) { choose(query) }
        .onChange(of: query) { _, new in
            // Clearing the field comes back to the list rather than stranding
            // you on results for something you just deleted.
            if new.isEmpty, selected != nil { back() }
        }
        .task { await loadPlaces() }
    }

    // MARK: - Places

    private var filtered: [PlaceSummary] {
        guard !query.isEmpty else { return places }
        return places.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var placesList: some View {
        if isLoadingPlaces {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            ContentUnavailableView(
                "Can't Search Right Now", systemImage: "wifi.slash", description: Text(failure)
            )
        } else if places.isEmpty {
            // Not an error. A library of scans and screenshots has no
            // coordinates in it, and saying so is more use than an empty list.
            ContentUnavailableView(
                "No Places Yet",
                systemImage: "mappin.slash",
                description: Text(
                    "Photos taken with location turned on show the place they "
                    + "were taken. None of the photos in \(space.name) have one yet."
                )
            )
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(filtered) { place in
                Button {
                    choose(place.name)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.tint)
                        Text(place.name).foregroundStyle(.primary)
                        Spacer()
                        Text("\(place.count)")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsGrid(for place: String) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(total == 1 ? "1 photo" : "\(total) photos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    // Flat and date-ordered: a result set is not a library, and
                    // day headers over eleven photos from four years would be
                    // more chrome than content.
                    PhotoGridSection(
                        entries: results.map { GridEntry.item($0) },
                        width: proxy.size.width,
                        targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                        spacing: spacing,
                        columns: TimelineZoom.day.columns
                    ) { entry, size in
                        if case .item(let item) = entry {
                            NavigationLink {
                                AssetDetailView(
                                    item: item, space: space, session: session,
                                    pageItems: results
                                )
                            } label: {
                                PhotoCell(item: item, loader: session.loader, size: size)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, spacing)

                    if nextOffset != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .task { await loadMore(place: place) }
                    }
                }
            }
        }
        .overlay {
            if isSearching, results.isEmpty { ProgressView() }
            if !isSearching, results.isEmpty, failure == nil {
                ContentUnavailableView.search(text: place)
            }
        }
    }

    // MARK: - Loading

    private func loadPlaces() async {
        guard let client = session.client else { return }
        isLoadingPlaces = true
        defer { isLoadingPlaces = false }
        do {
            places = try await client.places(spaceID: space.id).places
            failure = nil
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }

    private func choose(_ place: String) {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Put it in the field even when it came from the list. The search bar
        // covers the navigation title on this screen, so without this a tapped
        // place gives you a grid of photos with nothing anywhere saying which
        // place they are from — and no obvious way back but guessing.
        query = trimmed
        selected = trimmed
        results = []
        total = 0
        nextOffset = 0
        Task { await loadMore(place: trimmed) }
    }

    private func back() {
        selected = nil
        results = []
        total = 0
        nextOffset = nil
    }

    /// Fetches the next page, or the first when `nextOffset` is zero.
    private func loadMore(place: String) async {
        guard let client = session.client, let offset = nextOffset, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await client.search(
                spaceID: space.id, place: place, offset: offset
            )
            // Guard against a page arriving after the user has moved on.
            guard selected == place else { return }
            results.append(contentsOf: page.items)
            total = page.total
            nextOffset = page.nextOffset
            failure = nil
        } catch {
            nextOffset = nil
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }
}
