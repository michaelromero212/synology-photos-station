import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Search, scoped to one space.
///
/// Before anything is typed, the screen says how search works in a sentence and
/// offers a few searches to start from: your recent ones, and a handful the
/// library will answer — its two most photographed places, a few subjects of
/// different kinds, a year (see `SearchSuggestionsResponse`). Each one fills
/// in the field as it runs, so it teaches by example what typing can do.
///
/// It used to open on two lists, a dozen things and a dozen places, and the
/// things were Vision's labels in order of how often they appear: in a
/// family's photos that's "Conveyance" (a vehicle), "Portal" (a door),
/// furniture, windows and curtains. Twenty-five rows that read as noise, where
/// Photos opens on recent searches and two suggestions.
///
/// Typing searches the server rather than filtering what happens to be loaded,
/// and lists the places and things that match. Submitting what was typed
/// searches places, things, years and months together, every word of which has
/// to match: "beach 2024", "dog Culpeper", "july fireworks".
@MainActor
struct SearchView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    /// What the results are for. A place picked from its list is matched as
    /// a place, exactly as before. Anything typed, or a thing picked, is read
    /// by the server word by word.
    fileprivate typealias RecentSearch = Search
    fileprivate enum Search: Hashable {
        case place(String)
        case text(String)

        var title: String {
            switch self {
            case .place(let name), .text(let name): name
            }
        }
    }

    /// What matches what's being typed.
    @State private var things: [ThingSummary] = []
    @State private var places: [PlaceSummary] = []
    /// How many distinct places the library has. What the "All Places" row
    /// counts.
    @State private var placeTotal = 0
    /// What the landing screen offers to search. See `SearchSuggestion`.
    @State private var suggestions: [SearchSuggestion] = []
    /// Whether what's in a photo can be searched for. It can't for someone who
    /// turned recognizing it off, and the how-to line shouldn't say it can.
    @State private var recognizesContent = true
    @State private var recents: [RecentSearches.Entry] = []
    /// On a Mac the window owns the query, because the field lives in the
    /// window's toolbar and is there whether or not you are looking at search
    /// results — so the text has to outlive this view. Everywhere else this
    /// screen *is* the search, and owns it.
    #if os(macOS)
    @Binding var query: String
    #else
    @State private var query = ""
    #endif
    @State private var selected: Search?
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
                suggestionsList
            }
        }
        // A shared album's name, because the same button searches whichever
        // library you pressed it over, and "Search" alone would claim all of
        // them.
        .navigationTitle(selected?.title ?? (space.kind == .shared ? space.name : "Search"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Not on macOS: the window put the field in its toolbar already, and a
        // second `.searchable` inside the detail pane would draw a second one.
        #if !os(macOS)
        .searchable(text: $query, placement: Self.searchPlacement, prompt: "Search your photos")
        .onSubmit(of: .search) { choose(.text(query)) }
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
            if query.isEmpty {
                await loadLanding()
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await loadMatches(for: query)
            }
        }
        .navigationDestination(isPresented: $showAllPlaces) {
            AllPlacesView(session: session, space: space, total: placeTotal) { name in
                showAllPlaces = false
                choose(.place(name))
            }
        }
    }

    // MARK: - Before and while typing

    @ViewBuilder
    private var suggestionsList: some View {
        if isLoadingPlaces {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            ContentUnavailableView(
                "Can't Search Right Now", systemImage: "wifi.slash", description: Text(failure)
            )
        } else if query.isEmpty {
            landing
        } else if places.isEmpty, things.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            matches
        }
    }

    /// How it works, recent searches, a few to try, and every place.
    @ViewBuilder
    private var landing: some View {
        if suggestions.isEmpty, recents.isEmpty, placeTotal == 0 {
            // Not an error. A library of scans and screenshots has no
            // coordinates or dates worth suggesting, and saying so is more use
            // than an empty screen.
            ContentUnavailableView(
                "Nothing to Search Yet",
                systemImage: "magnifyingglass",
                description: Text(
                    "Photos taken with location turned on can be found by place. "
                    + "Once your iPhone has analyzed your photos, they can be found "
                    + "by what's in them, too."
                )
            )
        } else {
            List {
                Section {
                    // Lined up with the headings under it.
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }

                if !recents.isEmpty {
                    Section {
                        ForEach(recents) { entry in
                            RecentRow(entry: entry) { choose(entry.search) }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") {
                                RecentSearches.clear(for: session.user?.id)
                                recents = []
                            }
                            .font(.subheadline)
                            #if !os(tvOS)
                            .buttonStyle(.borderless)
                            #endif
                        }
                    }
                }

                if !suggestions.isEmpty {
                    Section("Try") {
                        FlowLayout(spacing: 8) {
                            ForEach(suggestions) { suggestion in
                                SuggestionChip(suggestion: suggestion) {
                                    choose(suggestion.kind == .place
                                        ? .place(suggestion.query) : .text(suggestion.query))
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                }

                // Every place, A to Z, for anyone who'd rather browse than type.
                if placeTotal > 0 {
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
            #if os(iOS)
            // A sentence, a few chips and one row: grouped list spacing made
            // them read as four separate screens, the sentence a long way
            // under the field it explains.
            .listSectionSpacing(.compact)
            .contentMargins(.top, 8, for: .scrollContent)
            #endif
        }
    }

    /// What search understands, in one line, with an example that mixes kinds.
    private var hint: String {
        recognizesContent
            ? "Search by place, what's in a photo, or a year. Mix them, like “beach 2024”."
            : "Search by place or by year. Mix them, like “Florida 2024”."
    }

    /// The places and things that match what's typed.
    private var matches: some View {
        List {
            if !things.isEmpty {
                Section("Things") {
                    ForEach(things) { thing in
                        ThingRow(thing: thing) { choose(.text(thing.name)) }
                    }
                }
            }
            if !places.isEmpty {
                Section("Places") {
                    ForEach(places) { place in
                        PlaceRow(place: place) { choose(.place(place.name)) }
                    }
                }
            }
        }
        .placesListStyle()
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsGrid(for search: Search) -> some View {
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
                            .task { await loadMore(for: search) }
                    }
                }
            }
        }
        .overlay {
            if isSearching, results.isEmpty { ProgressView() }
            if !isSearching, results.isEmpty, failure == nil {
                ContentUnavailableView.search(text: search.title)
            }
        }
    }

    // MARK: - Loading

    /// What the screen offers before anything is typed.
    private func loadLanding() async {
        guard let client = session.client else { return }
        recents = RecentSearches.load(for: session.user?.id)
        // Only the very first load gets a spinner. Coming back to the empty
        // field shouldn't blank what's there.
        if suggestions.isEmpty, placeTotal == 0 { isLoadingPlaces = true }
        defer { isLoadingPlaces = false }
        await session.loadCapabilities()
        do {
            if session.supports(ServerCapability.searchSuggestions) {
                async let offered = client.searchSuggestions(spaceID: space.id)
                // Only the count, for the All Places row.
                async let counted = client.places(spaceID: space.id, limit: 1)
                let response = try await offered
                suggestions = response.suggestions
                recognizesContent = response.recognizesContent
                placeTotal = try await counted.total
            } else {
                // A NAS from before suggestions: its most photographed places,
                // which every NAS can list. Its things are Vision's raw labels,
                // which is what this screen stopped offering.
                let response = try await client.places(spaceID: space.id, limit: 3)
                suggestions = response.places.map { place in
                    SearchSuggestion(
                        kind: .place,
                        title: place.name.split(separator: ",").first.map(String.init) ?? place.name,
                        query: place.name
                    )
                }
                placeTotal = response.total
                let things = try? await client.things(spaceID: space.id, limit: 1)
                recognizesContent = (things?.total ?? 0) > 0
            }
            failure = nil
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }

    /// The places and things matching what's typed.
    private func loadMatches(for query: String) async {
        guard let client = session.client else { return }
        // More rows than a landing list would show: a match list that stops at
        // twelve looks like the answer isn't there.
        async let placesAnswer = client.places(spaceID: space.id, matching: query, limit: 60)
        // Quietly empty when it fails. A NAS that predates things, or a
        // library not analyzed yet, still searches by place.
        let thingsAnswer = try? await client.things(spaceID: space.id, matching: query, limit: 30)
        do {
            places = try await placesAnswer.places
            things = thingsAnswer?.things ?? []
            failure = nil
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }

    private func choose(_ search: Search) {
        let trimmed = search.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Put it in the field even when it came from a list. The search bar
        // covers the navigation title on this screen, so without this a tapped
        // row gives you a grid of photos with nothing anywhere saying what
        // they were found by, and no obvious way back but guessing.
        query = trimmed
        let chosen: Search = switch search {
        case .place: .place(trimmed)
        case .text: .text(trimmed)
        }
        if case .place = chosen {
            RecentSearches.record(.init(text: trimmed, isPlace: true), for: session.user?.id)
        } else {
            RecentSearches.record(.init(text: trimmed, isPlace: false), for: session.user?.id)
        }
        #if os(iOS)
        // The keyboard down, so the photos have the screen. Picked from a list
        // or a chip with the field still focused, it stayed up over half of
        // them. The field keeps what was searched for.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        #endif
        selected = chosen
        results = []
        total = 0
        nextOffset = 0
        Task { await loadMore(for: chosen) }
    }

    private func back() {
        selected = nil
        results = []
        total = 0
        nextOffset = nil
    }

    /// Fetches the next page, or the first when `nextOffset` is zero.
    private func loadMore(for search: Search) async {
        guard let client = session.client, let offset = nextOffset, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = switch search {
            case .place(let name):
                try await client.search(spaceID: space.id, place: name, offset: offset)
            case .text(let text):
                try await client.search(spaceID: space.id, text: text, offset: offset)
            }
            // Guard against a page arriving after the user has moved on.
            guard selected == search else { return }
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

/// Searches made on this device, newest first, for the landing screen.
///
/// Kept on the device rather than the NAS: they're a convenience for whoever
/// holds this phone, not part of the library. Per account, and forgotten on
/// signing out (see `AppSession.signOut`), because a search says what someone
/// went looking for.
@MainActor
enum RecentSearches {
    struct Entry: Codable, Hashable, Identifiable {
        let text: String
        /// A place picked from a list, rather than words typed or a chip
        /// tapped. Searched as a place again.
        let isPlace: Bool

        var id: String { (isPlace ? "place:" : "text:") + text.lowercased() }
    }

    static let limit = 5
    private static let prefix = "search.recent."

    static func load(for userID: UUID?) -> [Entry] {
        guard let userID,
              let data = UserDefaults.standard.data(forKey: prefix + userID.uuidString)
        else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// First, and only once: searching for the same thing again moves it up.
    static func record(_ entry: Entry, for userID: UUID?) {
        guard let userID else { return }
        var entries = load(for: userID).filter { $0.id != entry.id }
        entries.insert(entry, at: 0)
        save(Array(entries.prefix(limit)), for: userID)
    }

    static func clear(for userID: UUID?) {
        guard let userID else { return }
        UserDefaults.standard.removeObject(forKey: prefix + userID.uuidString)
    }

    /// Every account's, for signing out.
    static func forgetAll() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func save(_ entries: [Entry], for userID: UUID) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: prefix + userID.uuidString)
    }
}

private extension RecentSearches.Entry {
    var search: SearchView.RecentSearch {
        isPlace ? .place(text) : .text(text)
    }
}

/// A search made before, to make again.
private struct RecentRow: View {
    let entry: RecentSearches.Entry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(entry.text).foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search \(entry.text) again")
    }
}

/// One search to try, as a capsule: a pin, a sparkle or a calendar for what
/// kind it is, and what it searches for.
private struct SuggestionChip: View {
    let suggestion: SearchSuggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                Text(suggestion.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.quaternary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search \(suggestion.title)")
    }

    private var symbol: String {
        switch suggestion.kind {
        case .place: "mappin.and.ellipse"
        case .thing: "sparkles"
        case .year: "calendar"
        }
    }
}

/// Lays its views out in rows, starting a new one when the next won't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, in: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            // Never wider than the row, so a long name truncates rather than
            // running off the edge.
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            var row = rows.removeLast()
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let next = Row(y: row.y + row.height + spacing)
                rows.append(row)
                row = next
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x, size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows.append(row)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// One thing the photos show, with how many show it.
private struct ThingRow: View {
    let thing: ThingSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(thing.name).foregroundStyle(.primary)
                Spacer()
                Text("\(thing.count)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
