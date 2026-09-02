import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Search, scoped to one space.
///
/// The screen is useful before anything is typed: it opens on the places this
/// library actually has photos from, commonest first, with counts. That is the
/// difference between a search box — which asks you to guess what the app
/// knows — and a way in.
///
/// It shows a *handful*, not all of them, and that is the whole design. A
/// library accumulates one entry per town anyone ever drove through, so the
/// full list is a dozen genuinely useful rows followed by several hundred with
/// a count of one. Ordering by count makes the top good and does nothing about
/// the tail, which is most of the list. So the landing screen is bounded and
/// the rest lives behind "All Places" — the shape Apple uses everywhere it has
/// more content than screen.
///
/// Typing searches the server rather than filtering what happens to be loaded.
/// Filtering locally would have quietly meant search only worked on the twelve
/// places already on screen.
///
/// One axis for now, deliberately. Place names are filled in at import for
/// every photo carrying GPS, so this works on day one across a whole library;
/// tags exist only where somebody typed one.
@MainActor
struct SearchView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var places: [PlaceSummary] = []
    /// How many distinct places exist, which is usually far more than `places`
    /// holds. What the "All Places" row counts.
    @State private var placeTotal = 0
    /// On a Mac the window owns the query, because the field lives in the
    /// window's toolbar and is there whether or not you are looking at search
    /// results — so the text has to outlive this view. Everywhere else this
    /// screen *is* the search, and owns it.
    #if os(macOS)
    @Binding var query: String
    #else
    @State private var query = ""
    #endif
    @State private var selected: String?
    @State private var showAllPlaces = false
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
        // Not on macOS: the window put the field in its toolbar already, and a
        // second `.searchable` inside the detail pane would draw a second one.
        #if !os(macOS)
        .searchable(text: $query, placement: Self.searchPlacement, prompt: "Places")
        .onSubmit(of: .search) { choose(query) }
        #endif
        .onChange(of: query) { _, new in
            // Clearing the field comes back to the list rather than stranding
            // you on results for something you just deleted.
            if new.isEmpty, selected != nil { back() }
        }
        // Searches the server as you type, debounced. The alternative — filter
        // the loaded array — silently limits search to whatever the landing
        // screen happened to fetch.
        .task(id: query) {
            guard selected == nil else { return }
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            await loadPlaces(matching: query)
        }
        .navigationDestination(isPresented: $showAllPlaces) {
            AllPlacesView(session: session, space: space, total: placeTotal) { name in
                showAllPlaces = false
                choose(name)
            }
        }
    }

    // MARK: - Places

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
        } else if places.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                Section {
                    ForEach(places) { place in
                        PlaceRow(place: place) { choose(place.name) }
                    }
                } header: {
                    // Only worth a heading when it is a selection rather than
                    // the lot; over twelve places it explains why the list
                    // stops, and under it the heading would be a lie.
                    if query.isEmpty, placeTotal > places.count {
                        Text("Most Photographed")
                    }
                }

                // The way to everything the landing screen left out, and it
                // says how much that is — a bare "All Places" gives no sense of
                // whether the next screen holds twenty rows or eight hundred.
                if query.isEmpty, placeTotal > places.count {
                    Section {
                        Button {
                            showAllPlaces = true
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)
                                Text("All Places").foregroundStyle(.primary)
                                Spacer()
                                Text("\(placeTotal)")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .placesListStyle()
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

    /// Fetches the landing screen's handful, or the matches for what's typed.
    private func loadPlaces(matching query: String = "") async {
        guard let client = session.client else { return }
        // Only the very first load gets a spinner. Re-running this on every
        // keystroke would otherwise blank the list under the cursor.
        if places.isEmpty { isLoadingPlaces = true }
        defer { isLoadingPlaces = false }
        do {
            // More rows while searching: a match list that stops at twelve
            // looks like the answer isn't there.
            let response = try await client.places(
                spaceID: space.id, matching: query,
                limit: query.isEmpty ? 12 : 60
            )
            places = response.places
            placeTotal = response.total
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

/// One place, with how many photos came from it.
private struct PlaceRow: View {
    let place: PlaceSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(place.name).foregroundStyle(.primary)
                Spacer()
                Text("\(place.count)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Everything the landing screen left out.
///
/// Alphabetical here, where the landing screen is by count — two screens doing
/// two different jobs. The landing answers "where do we take photographs", so
/// the commonest belong at the top. This one answers "I know the name, find
/// it", and for that an A–Z with a scrub index beats any relevance order: you
/// already know what you're looking for, you just need to reach it.
struct AllPlacesView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let total: Int
    let onPick: (String) -> Void

    @State private var places: [PlaceSummary] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        Group {
            if isLoading, places.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, places.isEmpty {
                ContentUnavailableView(
                    "Can't Load Places", systemImage: "wifi.slash", description: Text(failure)
                )
            } else if places.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list
            }
        }
        .navigationTitle("All Places")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, prompt: "Places")
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
    }

    /// Sectioned by first letter, which is what earns the index down the side.
    private var sections: [(letter: String, places: [PlaceSummary])] {
        let grouped = Dictionary(grouping: places) { place -> String in
            let first = place.name.prefix(1).uppercased()
            // Anything not A–Z shares one bucket rather than each punctuation
            // mark getting an index entry of its own.
            return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private var list: some View {
        List {
            ForEach(sections, id: \.letter) { section in
                Section {
                    ForEach(section.places) { place in
                        PlaceRow(place: place) { onPick(place.name) }
                    }
                } header: {
                    Text(section.letter)
                }
                .id(section.letter)
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        guard let client = session.client else { return }
        if places.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            // The whole vocabulary, alphabetically. Bounded by the server's own
            // ceiling rather than paged: this is one short string and an integer
            // per row, so even a library with two thousand places is a small
            // response — and paging an A–Z list would break the scrub index,
            // which has to know every section to be worth having.
            let response = try await client.places(
                spaceID: space.id, matching: query, limit: 2000, alphabetical: true
            )
            places = response.places
            failure = nil
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }
}

private extension View {
    /// Grouped on iPhone, where the "All Places" row wants to sit apart from
    /// the places above it. `.insetGrouped` doesn't exist off iOS, and this is
    /// the second time that has broken the tvOS build — hence a named helper
    /// rather than the modifier spelled out at the call site.
    @ViewBuilder
    func placesListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.plain)
        #endif
    }
}
