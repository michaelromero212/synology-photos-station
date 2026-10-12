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
        if let saved = AlbumsSnapshotStore.loadAlbums() {
            albums = saved
            hasLoaded = true
            supportsFamily = saved.contains(where: \.isFamily)
        }
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
            albums = fresh
            supportsFamily = response.includesFamilyAlbums == true
            hasLoaded = true
            Task.detached(priority: .utility) { AlbumsSnapshotStore.saveAlbums(fresh) }
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
                    family(store, side: side)
                    sharedLibraries()
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

    /// The one card the page opens on.
    ///
    /// Picked by the server, which also takes whatever it picked out of the
    /// sections below so the same place is never offered twice — see its
    /// `heroKey`. Absent rather than empty on a library too young to have
    /// noticed anything, in which case the page simply starts with the shelves.
    @ViewBuilder
    private func hero(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        if let hero = found.hero {
            NavigationLink {
                CollectionDetailView(session: session, space: space, collection: hero)
            } label: {
                CollectionHeroCard(collection: hero, loader: session.loader)
            }
            .buttonStyle(.plain)
            .nameable(hero) { naming = $0 }
            .padding(.horizontal, spacing)
        }
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

    /// The albums that are yours alone.
    @ViewBuilder
    private func manual(_ store: AlbumStore, side: CGFloat) -> some View {
        let albums = store.personal
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Your Albums")
                albumGrid(albums, store: store, side: side)
            }
        }
    }

    /// Albums in the shared libraries you're in: every member sees them, so
    /// they sit apart from yours, each saying whose library it's in.
    ///
    /// On every platform, unlike the libraries below them. These are albums,
    /// and the Mac's sidebar lists libraries, not albums.
    @ViewBuilder
    private func family(_ store: AlbumStore, side: CGFloat) -> some View {
        let albums = store.family
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Shared Albums")
                albumGrid(albums, store: store, side: side)
            }
        }
    }

    private func albumGrid(_ albums: [AlbumDTO], store: AlbumStore, side: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(session: session, album: album, store: store)
                } label: {
                    AlbumCard(
                        album: album, side: side, loader: session.loader,
                        library: libraryName(of: album)
                    )
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
        }
        .padding(.horizontal, spacing)
    }

    /// The shared library a family album is in, by name.
    private func libraryName(of album: AlbumDTO) -> String? {
        guard let spaceID = album.spaceID else { return nil }
        return session.sharedSpaces.first { $0.id == spaceID }?.name
    }

    /// What the family shares, on the same page as what you filed yourself.
    ///
    /// These had a tab of their own. It was the wrong shape twice over: a whole
    /// tab that was empty for anyone who shares nothing, and — for anyone who
    /// does — a second place to go looking for "a set of photos with a name on
    /// it", which is exactly what an album is. Photos puts Shared Albums on the
    /// same page as your own albums, and it is right: the thing that differs is
    /// who can see them, not what they are.
    ///
    /// Below your own albums rather than above. Yours are the ones you reach
    /// for daily; these are the ones you visit when somebody adds to them, and
    /// the notification is what sends you.
    ///
    /// Not on a Mac. A window has a sidebar, and the sidebar already gives every
    /// shared album a row of its own — putting them here as well would be the
    /// same list twice, and these rows would be the dead half of it, since the
    /// destination that answers them belongs to the tab bar's stack.
    ///
    /// "Shared Libraries", not "Shared Albums", since albums can now live inside
    /// them: a library is where the family's photos are, and a shared album is
    /// a set of them with a name.
    @ViewBuilder
    private func sharedLibraries() -> some View {
        #if !os(macOS)
        let shared = session.sharedSpaces
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Shared Libraries")
                VStack(spacing: 8) {
                    ForEach(shared) { space in
                        NavigationLink(value: SharedAlbumRoute(spaceID: space.id)) {
                            sharedAlbumRow(space)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, spacing)
            }
        }
        #endif
    }

    #if !os(macOS)
    private func sharedAlbumRow(_ space: SpaceDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(
                    .quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(space.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // The people, not the photographs. A shared album's count
                // changes whenever anyone adds anything, so a number of photos
                // here would be wrong more often than right — and who is in it
                // is the fact that makes it different from an album of your own.
                Text(
                    space.memberCount == 1
                        ? "Just you" : "\(space.memberCount) people"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
    }
    #endif

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

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .default, weight: .bold))
            .tracking(-0.3)
            .padding(.horizontal, spacing)
            .padding(.bottom, 10)
    }

}

private struct AlbumCard: View {
    let album: AlbumDTO
    let side: CGFloat
    let loader: ThumbnailLoader?
    /// The shared library a family album is in, said under its name.
    var library: String?

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
                    Image(systemName: "rectangle.stack")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .clipped()

            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(details)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: album.coverAssetID) {
            guard let assetID = album.coverAssetID, let loader else { return }
            cover = await loader.thumbnail(assetID: assetID, size: 512)
        }
    }

    private var details: String {
        let count = "\(album.itemCount) item\(album.itemCount == 1 ? "" : "s")"
        guard let library else { return count }
        return "\(library) · \(count)"
    }
}

/// Making an album: a name, and who can see it.
///
/// Yours alone unless you choose a shared library, where everyone in it sees
/// the album and can add to it. The choice is made here, once: an album
/// doesn't move between the two.
struct NewAlbumSheet: View {
    @Bindable var session: AppSession
    let store: AlbumStore
    /// Photos to start it with, when it's made from a selection.
    var spaceAssetIDs: [UUID] = []
    let onDone: (AlbumDTO?) -> Void

    @State private var name = ""
    /// The shared library it goes in. Nil for yours alone.
    @State private var library: UUID?
    @State private var isCreating = false

    /// The shared libraries a family album can go in: the ones you can add to,
    /// and only on a NAS that has family albums.
    private var libraries: [SpaceDTO] {
        guard store.supportsFamily else { return [] }
        return session.sharedSpaces.filter { $0.role != .viewer }
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
                        Text("Only you can see this album, even when it holds photos from a shared library.")
                    }
                } else {
                    Section {
                        Picker("Who can see it", selection: $library) {
                            Text("Only Me").tag(UUID?.none)
                            ForEach(libraries) { space in
                                Text(space.name).tag(UUID?.some(space.id))
                            }
                        }
                        #if !os(tvOS)
                        .pickerStyle(.inline)
                        // The section header says it; inline, the label would
                        // be a second "Who can see it" as the list's first row.
                        .labelsHidden()
                        #endif
                    } header: {
                        Text("Who can see it")
                    } footer: {
                        Text(footer)
                    }
                }
            }
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            let album = await store.create(
                                name: trimmed, spaceID: library, spaceAssetIDs: spaceAssetIDs
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

    private var footer: String {
        guard let library, let space = libraries.first(where: { $0.id == library }) else {
            return "Only you can see this album, even when it holds photos from a shared library."
        }
        return "Everyone in \(space.name) can see this album and add to it. "
            + "Photos you add from your own library are shared to \(space.name) too."
    }
}
