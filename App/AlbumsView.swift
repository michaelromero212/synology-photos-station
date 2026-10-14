import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AlbumStore {
    /// Yours alone and family albums, together. See `personal` and `family`.
    private(set) var albums: [AlbumDTO] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var hasLoaded = false
    /// Whether the NAS has family albums, which it says by listing them. Only
    /// then does New Album offer to put one in a shared library: an older
    /// server would quietly make it private.
    private(set) var supportsFamily = false

    var personal: [AlbumDTO] { albums.filter { !$0.isFamily } }
    var family: [AlbumDTO] { albums.filter(\.isFamily) }
    /// The shared libraries' covers and counts, for their cards under Shared
    /// Albums. Empty from a server that doesn't send them; the cards are then
    /// drawn from the session's spaces, without a cover.
    private(set) var libraries: [SharedLibrarySummary] = []

    private weak var session: AppSession?
    /// When the list was last answered, and how far into the personal
    /// library's changes it had got, for `isStale`.
    private var fetchedAt: Date?
    private var fetchedCursor: Int64?
    /// Set while a request is out, so a second caller doesn't send another.
    /// See `CollectionsStore.isRefreshing`.
    private var isRefreshing = false

    /// Starts from the list this device saw last, so the page has something to
    /// draw before the NAS answers. See `AlbumsSnapshotStore`. Counted as an
    /// answer: an old list is still a list, and the empty state should only
    /// show for a library that really has nothing.
    init(session: AppSession) {
        self.session = session
        let savedLibraries = AlbumsSnapshotStore.loadLibraries()
        if let saved = AlbumsSnapshotStore.loadAlbums() {
            albums = saved
            hasLoaded = true
        }
        libraries = savedLibraries ?? []
        // Only a NAS with shared albums sends library cards, so having saved
        // some — even none — means it has them. Inferring it from a saved
        // shared album alone left New Album without its Personal | Shared
        // choice on every launch, for exactly the person about to make their
        // first one.
        supportsFamily = savedLibraries != nil || albums.contains(where: \.isFamily)
    }

    /// Whether it is worth asking again.
    ///
    /// Albums live on the NAS against the account, not the device, so every
    /// device a person signs in on is already looking at the same list — but
    /// only as of the last time it asked. This is what makes that "already"
    /// true in practice rather than in principle: make an album on the phone
    /// and the iPad, sitting on the same page, went on showing the list it
    /// fetched when the tab was first built. The data was never out of sync;
    /// the screen was.
    ///
    /// A minute, matching the collections beside it, so flipping between tabs
    /// doesn't put a run of identical queries on a J4125 — but not when the
    /// library has changed under the list. A trashed photo can be an album's
    /// cover, and a count that still includes it is wrong.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        if libraryCursor != fetchedCursor { return true }
        return Date().timeIntervalSince(fetchedAt) > 60
    }

    /// See `AppSession.changeCursor`. The personal library's, because that is
    /// where an album's photos come from.
    private var libraryCursor: Int64? {
        guard let session, let personal = session.personalSpace else { return nil }
        return session.changeCursor(for: personal.id)
    }

    func refreshIfStale() async {
        guard isStale, !isRefreshing else { return }
        await refresh()
    }

    /// Asks again on the next visit. See `AppSession.hiddenContentChanged`.
    func expire() { fetchedAt = nil }

    func refresh() async {
        guard let client = session?.client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Only the first time. A refresh behind a list that is already on
        // screen must not announce itself — this drives the empty state, and
        // flipping it on every poll would make the page flicker between having
        // albums and deciding whether it has any.
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        // Before asking, as `CollectionsStore.refresh` does.
        let cursor = libraryCursor
        do {
            // Assigned only on success. A blip should cost you the update,
            // never the list you were looking at.
            let response = try await client.albums(includeFamily: true)
            let fresh = response.albums
            let shelves = response.libraries
            albums = fresh
            libraries = shelves ?? []
            supportsFamily = response.includesFamilyAlbums == true
            hasLoaded = true
            Task.detached(priority: .utility) {
                AlbumsSnapshotStore.saveAlbums(fresh)
                // Only what a NAS with shared albums sent; see `init`.
                if let shelves { AlbumsSnapshotStore.saveLibraries(shelves) }
            }
            fetchedAt = Date()
            fetchedCursor = cursor
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A new album: yours alone, or with `spaceID` a family album in that
    /// shared library, starting with `spaceAssetIDs` if there are any.
    @discardableResult
    func create(name: String, spaceID: UUID? = nil, spaceAssetIDs: [UUID] = []) async -> AlbumDTO? {
        guard let client = session?.client else { return nil }
        do {
            let album = try await client.createAlbum(
                CreateAlbumRequest(name: name, spaceAssetIDs: spaceAssetIDs, spaceID: spaceID)
            )
            await refresh()
            return album
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Whether it took. An album has no folder in File Station (only a shared
    /// library does), so a new name is the album's alone and nothing on the
    /// NAS moves.
    @discardableResult
    func rename(_ album: AlbumDTO, to name: String) async -> Bool {
        guard let client = session?.client else { return false }
        do {
            _ = try await client.updateAlbum(album.id, UpdateAlbumRequest(name: name))
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Whether it went. Only the album: its photos stay where they are.
    @discardableResult
    func delete(_ album: AlbumDTO) async -> Bool {
        guard let client = session?.client else { return false }
        do {
            try await client.deleteAlbum(album.id)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

extension AlbumDTO {
    /// What deleting it does, said before it's done: the album goes, and for a
    /// family album it goes for everyone; the photos never do.
    func deletionMessage(library: String?) -> String {
        if isFamily {
            let library = library ?? "the shared library"
            return "It's deleted for everyone in \(library). The photos stay in \(library)."
        }
        return "Only the album is deleted. The photos stay in your library."
    }
}

/// Where a tap on a shared album goes.
///
/// Carries the id rather than the `SpaceDTO`, because a pushed value is a
/// snapshot taken at the moment of the tap, and a shared album can be renamed
/// from inside itself. Resolving the id against the session on every body keeps
/// the title honest — the same staleness that once made a rename look as though
/// it hadn't taken.
struct SharedAlbumRoute: Hashable {
    let spaceID: UUID
}

/// Albums — what the library noticed, what you filed by hand, and what the
/// family shares.
///
/// Two halves. Above: collections the server worked out from dates and
/// coordinates — today in earlier years, days that stood out. Below: the albums
/// you made yourself.
///
/// The ordering is the argument. Apple's Albums tab reaches roughly twenty-five
/// rows before your own albums, most of them media types, and it reads as a
/// filing cabinet — organized by what a file *is* rather than by what happened.
/// So this opens on one hero, keeps the automatic sections few, drops any that
/// would be thin, and puts your own albums above the file-shaped stuff rather
/// than below it.
struct AlbumsView: View {
    @Bindable var session: AppSession

    @State private var store: AlbumStore?
    @State private var collections: CollectionsStore?
    @State private var showCreate = false
    /// The album waiting on "Delete Album?". Deleting used to happen on the
    /// menu tap itself, and an album somebody built by hand was one slip away
    /// from gone.
    @State private var deleting: AlbumDTO?
    /// Which of the top row's cards is showing, for its page dots.
    @State private var featuredCard: String?
    /// The card being named, if any. Held here rather than per-card so only one
    /// sheet can ever be up.
    ///
    /// Declared on every platform even though only iOS and macOS can present the
    /// sheet: the call sites that assign it sit inside shared layout code, and
    /// gating the property alone left tvOS with closures referring to something
    /// that wasn't there. An unused optional is cheaper than a fourth `#if`.
    @State private var naming: CollectionSummary?
    /// How many distinct places the library knows, for the Places row.
    ///
    /// Fetched here rather than added to the collections payload: the endpoint
    /// already exists and Search already calls it, and one small request is a
    /// cheaper thing to own than another field on a response that four clients
    /// decode.
    @State private var placeTotal = 0
    /// Which library `placeTotal` was counted for, when, and how far into its
    /// changes.
    @State private var placesFetched: (space: UUID, at: Date, cursor: Int64?)?
    /// The place the Places list handed back, pushed as its own screen.
    @State private var pickedPlace: String?
    @Environment(\.scenePhase) private var scenePhase

    private let columns = 2
    private let spacing: CGFloat = 14

    /// Starts from the session's stores, which are usually filled already —
    /// see `AppSession.albumStore`. Starting from nil and assigning them in a
    /// task drew a spinner for a frame first, even with everything ready.
    init(session: AppSession) {
        self.session = session
        _store = State(initialValue: session.albumStore())
        _collections = State(initialValue: session.personalSpace.map {
            session.collectionsStore(for: $0.id)
        })
        // The count from last time, until this visit's arrives. See
        // `AlbumsSnapshotStore`.
        _placeTotal = State(initialValue: session.personalSpace
            .flatMap { AlbumsSnapshotStore.loadPlaceTotal(spaceID: $0.id) } ?? 0)
    }

    /// Whether there is genuinely nothing to draw.
    ///
    /// "Nothing" and "not yet" are different answers and this has to tell them
    /// apart: treating an unanswered collections request as empty put the "no
    /// albums yet" screen over a library that had plenty, every time the
    /// request was slow or failed. So both halves must have actually reported
    /// before this is allowed to be true.
    private var hasNothing: Bool {
        guard let store, !store.isLoading else { return false }
        guard let collections, collections.hasLoaded else { return false }
        // Shared albums count, on the platforms that list them here. Without
        // this, someone whose whole use of the app is one family album saw
        // "Nothing to show yet" on the page their album lives on.
        #if !os(macOS)
        guard session.sharedSpaces.isEmpty else { return false }
        #endif
        return store.albums.isEmpty && (collections.page?.isEmpty ?? true)
    }

    var body: some View {
        Group {
            if let store {
                if hasNothing {
                    // Says what the page is *for*, not just that it is empty.
                    // "No albums yet" over a library that has plenty of photos
                    // reads as a fault; the truth is that trips and occasions
                    // need a few months of photographs behind them before there
                    // is anything to notice.
                    VStack(spacing: 0) {
                        ContentUnavailableView {
                            Label("Nothing to show yet", systemImage: "sparkles.rectangle.stack")
                        } description: {
                            Text(
                                "Trips, holidays and the days worth keeping appear here on "
                                + "their own as your library grows. You can also make an album "
                                + "by hand at any time."
                            )
                        } actions: {
                            Button("New Album") { showCreate = true }
                                .buttonStyle(.borderedProminent)
                        }
                        // The utilities stay reachable. They are the one thing
                        // that works on day one, and burying them behind an
                        // empty state would make Recently Deleted unreachable
                        // exactly when somebody has just deleted something.
                        if let space = session.personalSpace, let found = collections?.page {
                            utilities(found, space: space)
                                .padding(.bottom, spacing)
                        }
                    }
                } else {
                    page(store)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Albums")
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        // No Edit here. An album's settings — its name, who sees it, deleting
        // it — are in the album, behind the Edit button in its own grid, and a
        // shared library's in the library: you change the thing you're looking
        // at. This page had an Edit mode that badged every card and turned a
        // tap into "settings" instead of "open", which put a second meaning on
        // every card here for the sake of an occasional rename.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label("New Album", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            if let store {
                NewAlbumSheet(session: session, store: store) { _ in showCreate = false }
            }
        }
        #if !os(tvOS)
        .sheet(item: $naming) { collection in
            if let space = session.personalSpace {
                NameOccasionSheet(
                    session: session, spaceID: space.id, collection: collection
                ) { changed in
                    naming = nil
                    // Re-read rather than patch: the server decides what a day
                    // ends up called, and an annual name changes every year of
                    // it at once — not just the card that was tapped.
                    if changed { Task { await collections?.refresh() } }
                }
            }
        }
        #endif
        .navigationDestination(item: $pickedPlace) { place in
            if let space = session.personalSpace {
                CollectionDetailView(
                    session: session, space: space,
                    // `.revisit` is the kind that means "everything from one
                    // place, whenever it was" — exactly this, and already
                    // handled end to end.
                    collection: CollectionSummary(
                        kind: .revisit, key: place, title: place,
                        subtitle: nil, count: 0, coverAssetIDs: []
                    )
                )
            }
        }
        // The albums list needs no task of its own. The store comes from the
        // session, already built (see `init`), and the `.onAppear` below asks
        // again when it's stale (`AlbumStore.isStale`). This used to fetch it on
        // every visit: a tab's `.task` runs each time the tab is shown.
        .task(id: session.personalSpace?.id) {
            guard let space = session.personalSpace, let client = session.client else { return }
            // By the stores' rule either side of it: once a minute, or sooner
            // if the library has changed since (`AppSession.changeCursor`).
            let cursor = session.changeCursor(for: space.id)
            if let fetched = placesFetched, fetched.space == space.id,
               fetched.cursor == cursor,
               Date().timeIntervalSince(fetched.at) < 60 {
                return
            }
            // One row's worth: the count, not the list. The list is fetched by
            // the screen behind the row, and only if somebody opens it.
            //
            // Kept on failure, as the stores keep theirs: a blip shouldn't
            // take the row away.
            if let total = (try? await client.places(spaceID: space.id, limit: 1))?.total {
                placeTotal = total
                placesFetched = (space.id, Date(), cursor)
                let spaceID = space.id
                Task.detached(priority: .utility) {
                    AlbumsSnapshotStore.savePlaceTotal(total, spaceID: spaceID)
                }
            }
        }
        // Keyed on the space so switching personal libraries finds that
        // library's store, and separate from the albums load because either
        // can fail alone.
        //
        // The session's store, never a new one. This made a new store every
        // time the tab was shown, so the page came up without the hero, the
        // shelves, the trips and the occasions, and they arrived a moment later
        // on top, pushing everything below them down the screen. That was the
        // flicker switching to Albums: about 0.15 s against the dev server,
        // recorded in the simulator, and longer against the NAS.
        .task(id: session.personalSpace?.id) {
            guard let space = session.personalSpace else { return }
            let current = session.collectionsStore(for: space.id)
            if collections !== current { collections = current }
            await current.refreshIfStale()
        }
        // Coming back to the tab, or to the app, should not mean coming back to
        // a page somebody else changed an hour ago on a different device. The
        // collections are computed on the NAS from one library, so every
        // platform already agrees about *what* they are — this is what makes
        // them agree about *when*.
        // Albums alongside the collections, and that is the fix rather than an
        // afterthought: these three triggers existed and asked only about the
        // half of the page the server computes. The half you make yourself —
        // the albums — was fetched once when the tab was built and then never
        // again, so an album created on another device showed up on this one
        // only after the view happened to be torn down and rebuilt.
        .onAppear {
            Task { await collections?.refreshIfStale() }
            Task { await store?.refreshIfStale() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await collections?.refreshIfStale() }
            Task { await store?.refreshIfStale() }
        }
        // The backstop, for a device that is simply left on the page — an Apple
        // TV, or a Mac in a corner. It has no pull-to-refresh to reach for, and
        // half of what this page shows depends on what day it is.
        //
        // Ten minutes rather than the timeline's fifteen seconds: this is a
        // handful of aggregate queries where `/changes` is a cursor comparison,
        // and nothing here is urgent enough to be worth asking more often.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard !Task.isCancelled else { return }
                await collections?.refreshIfStale()
                await store?.refreshIfStale()
            }
        }
    }

    /// The page: what the library noticed, then what you filed.
    @ViewBuilder
    private func page(_ store: AlbumStore) -> some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            ScrollView {
                // Generous, and deliberately so. The page holds few things;
                // letting them sit apart is most of what stops it reading as a
                // list of settings.
                VStack(alignment: .leading, spacing: 30) {
                    if let space = session.personalSpace, let found = collections?.page {
                        // The hero opens the page. It sat third for a while,
                        // under the two standing shelves, on the argument that
                        // reassurance — "did this week's photographs get here" —
                        // beats a card about 2019. His call was the other way,
                        // and it is the better one: this is the only thing on
                        // the page you could not have gone looking for, so it
                        // has to be the thing you see without looking.
                        hero(found, space: space)
                        standing(found, space: space)
                        automatic(found, space: space)
                    }
                    manual(store, side: side)
                    shared(store, side: side)
                    if let space = session.personalSpace {
                        places(space: space)
                    }
                    if let space = session.personalSpace, let found = collections?.page {
                        utilities(found, space: space)
                    }
                }
                .padding(.vertical, spacing)
            }
            .refreshable {
                await store.refresh()
                await collections?.refresh()
            }
        }
    }


    /// The two shelves that are always there.
    ///
    /// Everything below these is the library's opinion — a trip it noticed, a
    /// day it thought was busy, a place you haven't been. These two are not
    /// opinions. One is "did my photographs get here", the other is "the ones I
    /// said I liked", and both are true on the first day and on the ten
    /// thousandth. A page made only of suggestions has nothing to stand on when
    /// it has nothing to suggest.
    ///
    /// Directly under the hero, and nothing else above them. These are what
    /// somebody came to the page *for*; everything below is the library
    /// volunteering something.
    @ViewBuilder
    private func standing(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        let shelves = [found.recentlyAdded, found.favorites].compactMap { $0 }
        if !shelves.isEmpty {
            VStack(spacing: 8) {
                ForEach(shelves, id: \.key) { shelf in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: shelf)
                    } label: {
                        CollectionRowCard(collection: shelf, loader: session.loader)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, spacing)
        }
    }

    /// The cards the page opens on, swiped through the way Photos opens on its
    /// featured memories and photos: what's tied to today, a featured photo or
    /// two, and the day's highlights, each saying why it's there.
    ///
    /// Picked and ordered by the server, which also takes the first out of the
    /// sections below so the same place is never offered twice in one glance —
    /// see its `heroKey`. One card is drawn as one card, and a server from
    /// before the row sends only that one. Absent on a library too young to
    /// have noticed anything, when the page simply starts with the shelves.
    @ViewBuilder
    private func hero(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        let cards = found.featured ?? found.hero.map { [$0] } ?? []
        if cards.count > 1 {
            VStack(spacing: 12) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(cards, id: \.featuredID) { card in
                            heroLink(card, space: space)
                                .padding(.horizontal, spacing)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $featuredCard)
                // The cards' shadows fall outside the row; clipped, each card
                // would sit in a hard-edged box. The neighbors are a whole
                // screen away either side, so nothing else shows.
                .scrollClipDisabled()
                PageDots(
                    count: cards.count,
                    current: cards.firstIndex { $0.featuredID == featuredCard } ?? 0
                )
            }
        } else if let card = cards.first {
            heroLink(card, space: space)
                .padding(.horizontal, spacing)
        }
    }

    private func heroLink(_ card: CollectionSummary, space: SpaceDTO) -> some View {
        NavigationLink {
            CollectionDetailView(session: session, space: space, collection: card)
        } label: {
            CollectionHeroCard(collection: card, loader: session.loader)
        }
        .buttonStyle(.plain)
        .nameable(card) { naming = $0 }
    }

    /// Everything else the server worked out: a few trips and a few occasions,
    /// each with the way to the rest. Each section is absent rather than empty
    /// when it found nothing — a heading with nothing under it is worse than no
    /// heading.
    ///
    /// A few, on purpose. This used to be every trip, every busy day and every
    /// place you hadn't been in years — up to eighteen rows before your own
    /// albums — and it was overwhelming. The server now chooses the ones that
    /// meant most; see `CollectionsController.featuredTrips`.
    @ViewBuilder
    private func automatic(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        // Trips before occasions: two weeks away is a bigger thing than most
        // single days, and the page should be ordered by what mattered rather
        // than by what happened most recently.
        if !found.trips.isEmpty {
            curated(
                "Trips", found.trips, all: found.allTrips, space: space,
                seeAll: \.allTrips
            )
        }
        if !found.days.isEmpty {
            curated(
                "Holidays & Occasions", found.days, all: found.allOccasions, space: space,
                seeAll: \.allOccasions
            )
        }
    }

    /// A handful of rows the server chose, under a heading that leads to the
    /// rest when there is more.
    private func curated(
        _ title: String, _ rows: [CollectionSummary], all: [CollectionSummary]?,
        space: SpaceDTO, seeAll: KeyPath<CollectionsResponse, [CollectionSummary]?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(title)
                Spacer(minLength: 8)
                // Only when See All would show something the page doesn't. A
                // server that predates it sends no list, and then there is no
                // button rather than one leading to an empty screen.
                if let all, all.count > rows.count, let collections {
                    NavigationLink {
                        CollectionListView(
                            session: session, space: space, title: title,
                            store: collections, list: seeAll
                        )
                    } label: {
                        Text("See All")
                            .font(.body)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, spacing)
                    .padding(.bottom, 10)
                }
            }
            ForEach(rows) { row in
                NavigationLink {
                    CollectionDetailView(session: session, space: space, collection: row)
                } label: {
                    CollectionRowCard(collection: row, loader: session.loader)
                        .padding(.horizontal, spacing)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .nameable(row) { naming = $0 }
            }
        }
    }

    /// Personal albums, and only those. New Album's "Personal" says this is
    /// where one goes, and the note under the heading says who sees them.
    @ViewBuilder
    private func manual(_ store: AlbumStore, side: CGFloat) -> some View {
        let albums = store.personal
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Albums", note: "Only you can see these.")
                albumGrid(albums, store: store, side: side)
            }
        }
    }

    private func albumGrid(_ albums: [AlbumDTO], store: AlbumStore, side: CGFloat) -> some View {
        LazyVGrid(columns: gridColumns(side: side), spacing: spacing) {
            ForEach(albums) { album in
                albumCell(album, store: store, side: side)
            }
        }
        .padding(.horizontal, spacing)
    }

    private func gridColumns(side: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns)
    }

    private func albumCell(_ album: AlbumDTO, store: AlbumStore, side: CGFloat) -> some View {
        browsableAlbumCell(
            album,
            card: AlbumCard(
                album: album, side: side, loader: session.loader, library: libraryName(of: album)
            ),
            store: store
        )
    }

    private func browsableAlbumCell(_ album: AlbumDTO, card: AlbumCard, store: AlbumStore) -> some View {
        NavigationLink {
            AlbumDetailView(session: session, album: album, store: store)
        } label: {
            card
        }
        .buttonStyle(.plain)
        .contextMenu {
            if album.mayManage {
                Button(role: .destructive) {
                    deleting = album
                } label: {
                    Label("Delete Album", systemImage: "trash")
                }
            }
        }
        // On the card, not the page: where the question appears as a
        // popover, it points at the album it's asking about.
        .confirmationDialog(
            "Delete “\(album.name)”?",
            isPresented: Binding(
                get: { deleting?.id == album.id },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                Task { await store.delete(album) }
            }
        } message: {
            Text(album.deletionMessage(library: libraryName(of: album)))
        }
    }

    /// A shared library as an album card, the same as the albums made in it:
    /// its most recently added photo for a cover, and who's in it and how
    /// much. Opens the whole library.
    private func libraryCell(_ space: SpaceDTO, store: AlbumStore, side: CGFloat) -> some View {
        NavigationLink(value: SharedAlbumRoute(spaceID: space.id)) {
            AlbumCard(
                library: space, summary: store.libraries.first { $0.id == space.id },
                side: side, loader: session.loader
            )
        }
        .buttonStyle(.plain)
    }

    /// The shared library a family album is in, by name.
    private func libraryName(of album: AlbumDTO) -> String? {
        guard let spaceID = album.spaceID else { return nil }
        return session.sharedSpaces.first { $0.id == spaceID }?.name
    }

    /// Everything shared, in one section: each shared library you're in, then
    /// the shared albums made in it.
    ///
    /// These had a tab of their own. It was the wrong shape twice over: a whole
    /// tab that was empty for anyone who shares nothing, and — for anyone who
    /// does — a second place to go looking for "a set of photos with a name on
    /// it", which is exactly what an album is. Photos puts Shared Albums on the
    /// same page as your own albums, and it is right: the thing that differs is
    /// who can see them, not what they are.
    ///
    /// Every card the same: the library is drawn as an album, its
    /// cover and counts beside the albums made in it, each library followed by
    /// its own albums so which belongs where needs no explaining. Personal
    /// albums are only ever under Albums.
    ///
    /// Below your own albums rather than above. Yours are the ones you reach
    /// for daily; these are the ones you visit when somebody adds to them, and
    /// the notification is what sends you.
    ///
    /// No library cards on a Mac. A window has a sidebar, and the sidebar
    /// already gives every shared library a row of its own — putting them here
    /// as well would be the same list twice, and these would be the dead half of
    /// it, since the destination that answers them belongs to the tab bar's
    /// stack. The albums show there all the same.
    @ViewBuilder
    private func shared(_ store: AlbumStore, side: CGFloat) -> some View {
        let cards = sharedCards(store)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // No line saying who can see these. It said what "shared"
                // already says, under the one heading on the page that says it.
                sectionHeader("Shared Albums")
                LazyVGrid(columns: gridColumns(side: side), spacing: spacing) {
                    ForEach(cards) { card in
                        switch card {
                        case .library(let space):
                            libraryCell(space, store: store, side: side)
                        case .album(let album):
                            albumCell(album, store: store, side: side)
                        }
                    }
                }
                .padding(.horizontal, spacing)
            }
        }
    }

    /// One card under Shared Albums: a whole shared library, or an album in one.
    private enum SharedCard: Identifiable {
        case library(SpaceDTO)
        case album(AlbumDTO)

        var id: UUID {
            switch self {
            case .library(let space): space.id
            case .album(let album): album.id
            }
        }
    }

    /// Each shared library, then its albums. Albums of a library this device
    /// hasn't heard of yet, and every one on a Mac, come last: shown, never
    /// dropped.
    private func sharedCards(_ store: AlbumStore) -> [SharedCard] {
        let albums = store.family
        #if os(macOS)
        let libraries: [SpaceDTO] = []
        #else
        let libraries = session.sharedSpaces
        #endif
        var cards: [SharedCard] = []
        for space in libraries {
            cards.append(.library(space))
            cards += albums.filter { $0.spaceID == space.id }.map(SharedCard.album)
        }
        cards += albums.filter { album in !libraries.contains { $0.id == album.spaceID } }
            .map(SharedCard.album)
        return cards
    }

    /// Set with a little more care than a list header usually gets: tighter
    /// tracking and a touch more weight, because these are the only words on
    /// the page that aren't either a photograph or a fact about one.
    /// A way in by *where*, which for an old library is often the only way in
    /// somebody has.
    ///
    /// "Somewhere near the lake, a few summers ago" is a question a person can
    /// actually ask; "August 2021" usually isn't. Every photograph with GPS
    /// already carries a place name from import, so this costs nothing to offer
    /// and gets better as the library grows.
    ///
    /// Reuses Search's list rather than growing a second one, and a picked
    /// place opens as a `revisit` collection, which is already keyed by place
    /// name and already knows how to fetch one. Nothing new on the server.
    @ViewBuilder
    private func places(space: SpaceDTO) -> some View {
        if placeTotal > 0 {
            NavigationLink {
                AllPlacesView(session: session, space: space, total: placeTotal) { name in
                    pickedPlace = name
                }
            } label: {
                utilityRow("Places", systemImage: "map", count: placeTotal)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, spacing)
        }
    }

    /// The file-shaped things, at the bottom, behind one door each.
    ///
    /// Apple gives media types a section apiece and the page becomes a filing
    /// cabinet. They are a filter over what you already have, not a thing that
    /// happened, so they sit below everything that did.
    @ViewBuilder
    private func utilities(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        VStack(spacing: 0) {
            if !found.mediaTypes.isEmpty {
                NavigationLink {
                    MediaTypesView(session: session, space: space, types: found.mediaTypes)
                } label: {
                    // The photographs behind them, not how many categories
                    // there are. "Media Types · 6" meaning six kinds sits in the
                    // same column as "Recently Deleted · 3" meaning three
                    // photos, and one of those readings has to win.
                    utilityRow(
                        "Media Types", systemImage: "square.grid.2x2",
                        count: found.mediaTypes.reduce(0) { $0 + $1.count }
                    )
                }
                .buttonStyle(.plain)
            }
            if let deleted = found.recentlyDeleted {
                NavigationLink {
                    RecentlyDeletedView(session: session, space: space)
                } label: {
                    utilityRow("Recently Deleted", systemImage: "trash", count: deleted.count)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, spacing)
    }

    private func utilityRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .font(.system(.body, design: .default, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// With `note`, a line under the heading saying who can see what's in it:
    /// the one thing that tells Albums and Shared Albums apart at a glance.
    private func sectionHeader(_ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(.title3, design: .default, weight: .bold))
                .tracking(-0.3)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, spacing)
        .padding(.bottom, 10)
    }

}

extension CollectionSummary {
    /// Unique within the top row: the server never puts one set of photos in
    /// it twice, and the kind keeps two cards apart even if it did.
    fileprivate var featuredID: String { "\(kind.rawValue)/\(key)" }
}

/// Which of the top row's cards is showing, and how many there are.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Card \(current + 1) of \(count)")
    }
}

/// One card on the Albums page: an album, or a shared library drawn as one.
private struct AlbumCard: View {
    let title: String
    let details: String
    let coverAssetID: UUID?
    let side: CGFloat
    let loader: ThumbnailLoader?
    /// What stands in for the cover while there's none.
    var placeholder = "rectangle.stack"

    @State private var cover: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let cover {
                    Image(platformImage: cover)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: placeholder)
                        .font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .clipped()

            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(details)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: coverAssetID) {
            guard let assetID = coverAssetID, let loader else { return }
            cover = await loader.thumbnail(assetID: assetID, size: 512)
        }
    }
}

extension AlbumCard {
    /// An album: its count, after its library's name if it's shared.
    init(album: AlbumDTO, side: CGFloat, loader: ThumbnailLoader?, library: String?) {
        let count = Self.count(album.itemCount)
        self.init(
            title: album.name, details: library.map { "\($0) · \(count)" } ?? count,
            coverAssetID: album.coverAssetID, side: side, loader: loader
        )
    }

    /// A shared library: who's in it and how much, its most recently added
    /// photo for a cover. Without a summary from the NAS, just who.
    init(library space: SpaceDTO, summary: SharedLibrarySummary?, side: CGFloat, loader: ThumbnailLoader?) {
        let members = summary?.memberCount ?? space.memberCount
        let people = members == 1 ? "Just you" : "\(members) people"
        self.init(
            title: space.name,
            details: summary.map { "\(people) · \(Self.count($0.itemCount))" } ?? people,
            coverAssetID: summary?.coverAssetID, side: side, loader: loader,
            placeholder: "person.2"
        )
    }

    static func count(_ items: Int) -> String {
        "\(items.formatted()) item\(items == 1 ? "" : "s")"
    }
}

/// Making an album: a name, and Personal or Shared.
///
/// Personal unless you choose Shared, which puts it in a shared library where
/// everyone sees it and can add to it. The footer says who can see it and
/// which section of the Albums page it will be in, so nobody has to guess
/// where it went. The choice is made here, once: an album doesn't move
/// between the two.
struct NewAlbumSheet: View {
    @Bindable var session: AppSession
    let store: AlbumStore
    /// Photos to start it with, when it's made from a selection.
    var spaceAssetIDs: [UUID] = []
    let onDone: (AlbumDTO?) -> Void

    enum Kind: Hashable { case personal, shared }

    @State private var name = ""
    @State private var kind = Kind.personal
    /// Which shared library, when there's more than one to choose from.
    @State private var library: UUID?
    @State private var isCreating = false

    /// The shared libraries a shared album can go in: the ones you can add
    /// to, and only on a NAS that has shared albums.
    private var libraries: [SpaceDTO] {
        guard store.supportsFamily else { return [] }
        return session.sharedSpaces.filter { $0.role != .viewer }
    }

    /// The library a shared album would go in: the one picked, or the only one.
    private var chosen: SpaceDTO? {
        guard kind == .shared else { return nil }
        return libraries.first { $0.id == library } ?? libraries.first
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Iceland 2012", text: $name)
                } header: {
                    Text("Name")
                }
                if libraries.isEmpty {
                    Section {
                    } footer: {
                        Text(Self.personalNote)
                    }
                } else {
                    Section {
                        Picker("Album type", selection: $kind) {
                            Text("Personal").tag(Kind.personal)
                            Text("Shared").tag(Kind.shared)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if kind == .shared, libraries.count > 1 {
                            Picker("Shared with", selection: Binding(
                                get: { chosen?.id }, set: { library = $0 }
                            )) {
                                ForEach(libraries) { space in
                                    Text(space.name).tag(UUID?.some(space.id))
                                }
                            }
                        }
                    } footer: {
                        Text(chosen.map(Self.sharedNote) ?? Self.personalNote)
                    }
                }
            }
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Opened before the app has heard from the NAS, the choice would
            // be missing and the album made personal by default. Asking here
            // brings the Personal | Shared switch in as soon as it answers.
            .task {
                if !store.supportsFamily { await store.refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            let album = await store.create(
                                name: trimmed, spaceID: chosen?.id, spaceAssetIDs: spaceAssetIDs
                            )
                            isCreating = false
                            onDone(album)
                        }
                    }
                    .disabled(trimmed.isEmpty || isCreating)
                }
            }
        }
    }

    static let personalNote = "Only you can see a personal album, even when it holds photos "
        + "from a shared library. You'll find it under Albums."

    static func sharedNote(_ space: SpaceDTO) -> String {
        "Everyone in \(space.name) can see a shared album and add to it. You'll find it "
            + "under Shared Albums. Photos you add from your own library are shared to "
            + "\(space.name) too."
    }
}

/// An album's settings, from the Edit button in its own grid: its name, who can
/// see it, and deleting it, as far as you may change them. Someone who can't is
/// told who can.
struct AlbumSettingsSheet: View {
    let album: AlbumDTO
    let store: AlbumStore
    /// The shared library a shared album is in, by name.
    let library: String?
    /// Told when the album is gone, before `onDone`, so the screen that was
    /// showing it can leave once these close.
    let onDeleted: () -> Void
    let onDone: () -> Void

    @State private var name: String
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var failure: String?

    init(
        album: AlbumDTO, store: AlbumStore, library: String?,
        onDeleted: @escaping () -> Void = {}, onDone: @escaping () -> Void
    ) {
        self.album = album
        self.store = store
        self.library = library
        self.onDeleted = onDeleted
        self.onDone = onDone
        _name = State(initialValue: album.name)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var whoSees: String {
        guard album.isFamily else {
            return "Only you can see this album. It's under Albums."
        }
        return "Everyone in \(library ?? "its shared library") can see this album. "
            + "It's under Shared Albums."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if album.mayManage {
                        TextField("Name", text: $name)
                    } else {
                        Text(album.name)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text(whoSees)
                }
                if album.mayManage {
                    Section {
                        Button("Delete Album", role: .destructive) { confirmDelete = true }
                    }
                } else {
                    Section {
                    } footer: {
                        Text("Only the person who made this album, or the owner of "
                            + "\(library ?? "its shared library"), can rename or delete it.")
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(album.isFamily ? "Shared Album" : "Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(album.mayManage ? "Cancel" : "Done", action: onDone)
                }
                if album.mayManage {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            isSaving = true
                            Task {
                                if await store.rename(album, to: trimmed) {
                                    onDone()
                                } else {
                                    failure = store.lastError ?? "That didn't save. Try again."
                                }
                                isSaving = false
                            }
                        }
                        .disabled(trimmed.isEmpty || trimmed == album.name || isSaving)
                    }
                }
            }
            .confirmationDialog(
                "Delete “\(album.name)”?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete Album", role: .destructive) {
                    Task {
                        if await store.delete(album) {
                            onDeleted()
                            onDone()
                        } else {
                            failure = store.lastError ?? "That didn't delete. Try again."
                        }
                    }
                }
            } message: {
                Text(album.deletionMessage(library: library))
            }
        }
    }
}

/// A shared library's settings, from the Edit button in its own grid: the same
/// screen Shared Libraries opens, so renaming it (and its folder in everyone's
/// File Station), its people, and leaving it work one way wherever they're
/// reached.
struct LibrarySettingsSheet: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let onDone: () -> Void

    @State private var model: SpacesModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    SpaceMembersView(
                        space: space, model: model, session: session,
                        onMembershipChanged: { Task { await session.refreshSpaces() } },
                        underTabBar: false
                    )
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .task {
            if model == nil, let client = session.client {
                model = SpacesModel(client: client)
            }
        }
    }
}
