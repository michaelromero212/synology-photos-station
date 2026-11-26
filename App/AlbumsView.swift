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
    /// Albums that belong to a shared library: everyone in it sees them.
    var family: [AlbumDTO] { albums.filter(\.isLibraryAlbum) }
    /// Albums shared with the people somebody chose: yours, and ones shared
    /// with you.
    var sharedWithPeople: [AlbumDTO] { albums.filter(\.isSharedWithPeople) }
    /// Whether the NAS shares albums with people, which it says by listing
    /// them when asked. See `AlbumListResponse.includesPeopleAlbums`.
    private(set) var supportsPeople = false
    /// The shared libraries' covers and counts, for their cards under Shared
    /// Albums. Empty from a server that doesn't send them; the cards are then
    /// drawn from the session's spaces, without a cover.
    private(set) var libraries: [SharedLibrarySummary] = []

    private weak var session: AppSession?
    /// When the list was last answered, and how far into the personal
    /// library's changes it had got, for `isStale`.
    private var fetchedAt: Date?
    private var fetchedCursor: Int64?
    /// And how many of this device's own changes it had seen. See
    /// `AppSession.libraryRevision`.
    private var fetchedRevision: Int?
    /// The request out now, so a second caller waits for its answer rather
    /// than sending another. See `CollectionsStore.inFlight`.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// So a slow answer never replaces a newer one.
    @ObservationIgnored private var asked = 0
    @ObservationIgnored private var answered = 0
    /// Holds the covers still while the page is on screen. See
    /// `CollectionsStore.take`.
    @ObservationIgnored private var hold: CoverHold<AlbumListResponse>!

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
        // Only a NAS that shares albums with people sends one.
        supportsPeople = albums.contains(where: \.isSharedWithPeople)
        hold = CoverHold(edits: session.editRevision) { [weak self] answer in
            self?.draw(answer)
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
        if session?.libraryRevision != fetchedRevision { return true }
        return Date().timeIntervalSince(fetchedAt) > 60
    }

    /// See `AppSession.changeCursor`. The personal library's, because that is
    /// where an album's photos come from.
    private var libraryCursor: Int64? {
        guard let session, let personal = session.personalSpace else { return nil }
        return session.changeCursor(for: personal.id)
    }

    /// With a request already out, waits for its answer instead. See
    /// `CollectionsStore.refreshIfStale`.
    func refreshIfStale() async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard isStale else { return }
        await refresh()
    }

    /// Asks again only if the library has moved since the last answer, however
    /// recent that was. For a page that's watching. See `LiveCounts`.
    func refreshIfChanged() async {
        guard inFlight == nil else { return }
        guard fetchedAt == nil || libraryCursor != fetchedCursor
                || session?.libraryRevision != fetchedRevision else { return }
        await refresh()
    }

    /// Asks again on the next visit. See `AppSession.hiddenContentChanged`.
    func expire() { fetchedAt = nil }

    /// Asks the NAS now, whatever else is out. `explicit` for a pull to
    /// refresh. See `CollectionsStore.refresh`.
    func refresh(explicit: Bool = false) async {
        let request = Task { await ask(explicit: explicit) }
        inFlight = request
        await request.value
        if inFlight == request { inFlight = nil }
    }

    private func ask(explicit: Bool) async {
        guard let client = session?.client else { return }
        // Only the first time. A refresh behind a list that is already on
        // screen must not announce itself — this drives the empty state, and
        // flipping it on every poll would make the page flicker between having
        // albums and deciding whether it has any.
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        asked += 1
        let number = asked
        // Before asking, as `CollectionsStore.ask` does.
        let cursor = libraryCursor
        let revision = session?.libraryRevision
        let edits = session?.editRevision ?? 0
        do {
            // Assigned only on success. A blip should cost you the update,
            // never the list you were looking at.
            // Always asked for: a NAS that predates albums shared with people
            // ignores the question.
            let response = try await client.albums(includeFamily: true, includePeople: true)
            guard number > answered else { return }
            answered = number
            let fresh = response.albums
            let shelves = response.libraries
            let hadList = hasLoaded
            hasLoaded = true
            Task.detached(priority: .utility) {
                AlbumsSnapshotStore.saveAlbums(fresh)
                // Only what a NAS with shared albums sent; see `init`.
                if let shelves { AlbumsSnapshotStore.saveLibraries(shelves) }
            }
            fetchedAt = Date()
            fetchedCursor = cursor
            fetchedRevision = revision
            lastError = nil
            take(response, edits: edits, explicit: explicit, hadList: hadList)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Puts an answer on the page, or holds its covers back until the page is
    /// left: each album's and each shared library's, by id. A shared library's
    /// cover is its newest photo, and it moves whenever somebody adds one;
    /// never while you're looking. See `CollectionsStore.take`, which this
    /// follows rule for rule.
    private func take(_ fresh: AlbumListResponse, edits: Int, explicit: Bool, hadList: Bool) {
        guard hadList, !explicit, !hold.editedSince(edits) else {
            hold.drawn(edits: edits)
            draw(fresh)
            return
        }
        let drawing = Set(Self.pictures(albums: albums, libraries: libraries))
        draw(fresh.keepingCovers(albums: albums, libraries: libraries))
        let pictures = Array(
            Self.pictures(albums: fresh.albums, libraries: fresh.libraries ?? [])
                .filter { !drawing.contains($0) }.prefix(40)
        )
        let loader = session?.loader
        hold.wait(for: fresh, edits: edits, isWarm: pictures.isEmpty) {
            if let loader { await CoverWarmer.warm(pictures, loader: loader) }
        }
    }

    /// Each only when it's different: assigning an equal value still redraws
    /// whatever reads it.
    private func draw(_ answer: AlbumListResponse) {
        if albums != answer.albums { albums = answer.albums }
        let shelves = answer.libraries ?? []
        if libraries != shelves { libraries = shelves }
        let family = answer.includesFamilyAlbums == true
        if supportsFamily != family { supportsFamily = family }
        let people = answer.includesPeopleAlbums == true
        if supportsPeople != people { supportsPeople = people }
    }

    /// The album and library covers the Albums page draws, yours first, at
    /// the size its cards draw them. See `AlbumCard`.
    private static func pictures(
        albums: [AlbumDTO], libraries: [SharedLibrarySummary]
    ) -> [CoverPicture] {
        // Every device's cards draw through `CollectionCover`, which trims
        // letterboxing.
        let covers = albums.filter { !$0.isFamily }.compactMap(\.cover)
            + albums.filter(\.isFamily).compactMap(\.cover)
            + libraries.compactMap(\.cover)
        return covers.map { CoverPicture(cover: $0, size: 512, trimmed: true) }
    }

    // MARK: On screen

    /// See `CollectionsStore.enterScreen`.
    func enterScreen() { hold.enter() }
    func leaveScreen(now: Bool) { hold.leave(now: now) }

    /// A new album: yours alone, shared with `memberIDs`, or with `spaceID` a
    /// family album in that shared library, starting with `spaceAssetIDs` if
    /// there are any.
    @discardableResult
    func create(
        name: String, spaceID: UUID? = nil, memberIDs: [UUID] = [], spaceAssetIDs: [UUID] = []
    ) async -> AlbumDTO? {
        guard let client = session?.client else { return nil }
        do {
            let album = try await client.createAlbum(
                CreateAlbumRequest(
                    name: name, spaceAssetIDs: spaceAssetIDs, spaceID: spaceID,
                    memberIDs: memberIDs.isEmpty ? nil : memberIDs
                )
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

    /// Whether it took. Nobody, and the album is yours alone again.
    @discardableResult
    func setPeople(_ album: AlbumDTO, to memberIDs: [UUID]) async -> Bool {
        guard let client = session?.client else { return false }
        do {
            _ = try await client.setAlbumPeople(album.id, memberIDs: memberIDs)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Whether it took: an album somebody shared with you, gone from your
    /// list. What you added stays in it for them.
    @discardableResult
    func leave(_ album: AlbumDTO) async -> Bool {
        guard let client = session?.client else { return false }
        do {
            try await client.leaveAlbum(album.id)
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

extension AlbumStore: CoverHolder {}

extension AlbumListResponse {
    /// This list as the page draws it while it's held: its albums and
    /// libraries, counts and names, with every one still here under the cover
    /// it has now, at the version it was drawn at. See `AlbumStore.take`.
    func keepingCovers(
        albums shownAlbums: [AlbumDTO], libraries shownLibraries: [SharedLibrarySummary]
    ) -> AlbumListResponse {
        let drawnAlbums = Dictionary(
            shownAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let drawnLibraries = Dictionary(
            shownLibraries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return AlbumListResponse(
            albums: albums.map { album in drawnAlbums[album.id].map(album.withCover(of:)) ?? album },
            includesFamilyAlbums: includesFamilyAlbums,
            libraries: libraries?.map { library in
                drawnLibraries[library.id].map(library.withCover(of:)) ?? library
            },
            includesPeopleAlbums: includesPeopleAlbums
        )
    }
}

extension AlbumDTO {
    /// The same album under the cover `drawn` has, at the version it was
    /// drawn at.
    func withCover(of drawn: AlbumDTO) -> AlbumDTO {
        guard drawn.coverAssetID != coverAssetID || drawn.coverVersion != coverVersion
        else { return self }
        return AlbumDTO(
            id: id, name: name, itemCount: itemCount,
            coverAssetID: drawn.coverAssetID, coverVersion: drawn.coverVersion,
            createdAt: createdAt, updatedAt: updatedAt, spaceID: spaceID,
            canManage: canManage, canAdd: canAdd, people: people, owner: owner
        )
    }
}

extension SharedLibrarySummary {
    /// The same library under the cover `drawn` has, at the version it was
    /// drawn at.
    func withCover(of drawn: SharedLibrarySummary) -> SharedLibrarySummary {
        guard drawn.coverAssetID != coverAssetID || drawn.coverVersion != coverVersion
        else { return self }
        return SharedLibrarySummary(
            id: id, name: name, memberCount: memberCount, itemCount: itemCount,
            coverAssetID: drawn.coverAssetID, coverVersion: drawn.coverVersion
        )
    }
}

extension AlbumDTO {
    /// What deleting it does, said before it's done: the album goes, and for a
    /// family album it goes for everyone; the photos never do.
    func deletionMessage(library: String?) -> String {
        if isSharedWithPeople {
            return "It's deleted for everyone it's shared with. Photos added to it stay in "
                + "the libraries they came from."
        }
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
    /// Set for an album shared with people, which is found by its own id
    /// first: its space is a new one each time it is shared again after being
    /// made personal, and the album is still the album.
    var albumID: UUID? = nil

    /// What this route opens, from what the device knows now.
    @MainActor
    func target(in session: AppSession) -> SharedAlbumTarget {
        let albums = session.albumStore().albums
        if let albumID, let album = albums.first(where: { $0.id == albumID }) {
            if let space = album.ownSpace { return .peopleAlbum(album, space) }
            return .album(album)
        }
        if let library = session.spaces.first(where: { $0.id == spaceID }) {
            return .library(library)
        }
        // From a notification, which knows only the space.
        if let album = albums.first(where: { $0.isSharedWithPeople && $0.spaceID == spaceID }),
           let space = album.ownSpace {
            return .peopleAlbum(album, space)
        }
        return .unavailable
    }
}

/// A screen the Albums tab pushes by value, and so keeps in its path: a shared
/// album, or Shared Albums on a screen of its own.
///
/// Shared Albums is pushed this way, where the page's other sections are pushed
/// as views, because its cards push shared albums by value. Whatever a view
/// link pushed stays above everything in the path, so a library opened from a
/// Shared Albums pushed as a view went in underneath it: the tap seemed to do
/// nothing, and Back uncovered the library (the iPhone simulator, iOS 27).
enum AlbumsRoute: Hashable {
    case shared(SharedAlbumRoute)
    case sharedAlbums
}

/// Where a shared album's route leads.
///
/// A shared library and an album shared with people both open as a library's
/// timeline — days, months, years, the scrubber — because both are a place a
/// family puts its photos, and the one difference that matters, who's in it,
/// is the Edit button's business. An album with no one else in it is
/// somebody's own album again, and opens as one.
enum SharedAlbumTarget {
    case library(SpaceDTO)
    /// The album, and its own space as a library the grid can show.
    case peopleAlbum(AlbumDTO, SpaceDTO)
    case album(AlbumDTO)
    case unavailable

    /// The library search looks in while this is on screen. Nil for none of
    /// its own: the personal library's.
    var searchSpace: SpaceDTO? {
        switch self {
        case .library(let space), .peopleAlbum(_, let space): space
        case .album, .unavailable: nil
        }
    }
}

extension AlbumDTO {
    /// The space an album shared with people keeps its photos in, as a library
    /// its grid can show. Nil for any other album.
    ///
    /// Only its people are members, and a photo is in it exactly while it is
    /// in the album — taking one out of the album takes it out of the space —
    /// so the space's timeline is the album, by date.
    ///
    /// Shared, so what somebody else added is theirs to remove, and the
    /// album's maker may remove anything (`SpacePermissions.mayRemove`), the
    /// rule the NAS applies to the album's own photos.
    var ownSpace: SpaceDTO? {
        guard isSharedWithPeople, let spaceID else { return nil }
        return SpaceDTO(
            id: spaceID, kind: .shared, name: name,
            role: mayManage ? .owner : mayAdd ? .contributor : .viewer,
            memberCount: (people?.count ?? 0) + 1
        )
    }
}

extension AlbumStore {
    /// One entry under Shared Albums: a whole shared library, or an album.
    enum SharedEntry: Identifiable {
        case library(SpaceDTO)
        case album(AlbumDTO)

        var id: UUID {
            switch self {
            case .library(let space): space.id
            case .album(let album): album.id
            }
        }
    }

    /// Everything under Shared Albums, in the page's order: albums shared with
    /// people first, then each shared library and its albums. Albums of a
    /// library this device hasn't heard of yet come last: shown, never dropped.
    ///
    /// The ones shared with people lead because they're the ones somebody
    /// made to share — the family album, the one with the cousins — where a
    /// library is everyone's backup landing in one place.
    ///
    /// The Albums page and the Mac's sidebar both list these, from here, so
    /// the two never disagree about what is shared.
    func sharedEntries(libraries: [SpaceDTO]) -> [SharedEntry] {
        let albums = family
        var entries: [SharedEntry] = sharedWithPeople.map(SharedEntry.album)
        for space in libraries {
            entries.append(.library(space))
            entries += albums.filter { $0.spaceID == space.id }.map(SharedEntry.album)
        }
        entries += albums.filter { album in !libraries.contains { $0.id == album.spaceID } }
            .map(SharedEntry.album)
        return entries
    }
}

/// Albums — what the library noticed, what you filed by hand, and what the
/// family shares — laid out the way Photos lays out its Collections.
///
/// Photos' sections in Photos' order: the memories the NAS picked for today,
/// what's pinned, the people in the photos, your albums and the shared ones,
/// what the library noticed, and the file-shaped things last. Each section
/// folds away under its title, and one with nothing in it yet says what will
/// be there, with the way to start it where there is one, rather than
/// vanishing.
///
/// One page for every device: a phone, an iPad, a Mac and a television show
/// the same sections under the same titles with the same cards. What differs
/// is how many cards fit across and whether a row scrolls sideways; see
/// `CollectionsLayout`.
struct AlbumsView: View {
    @Bindable var session: AppSession

    @State private var store: AlbumStore?
    @State private var collections: CollectionsStore?
    @State private var showCreate = false
    /// The card being named, if any. Held here rather than per-card so only one
    /// sheet can ever be up.
    ///
    /// Declared on every platform even though only iOS and macOS can present the
    /// sheet: the call sites that assign it sit inside shared layout code, and
    /// gating the property alone left tvOS with closures referring to something
    /// that wasn't there. An unused optional is cheaper than a fourth `#if`.
    @State private var naming: CollectionSummary?
    /// How many distinct places the library knows, for Places under Pinned
    /// and Utilities.
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
    #if !os(tvOS)
    /// The sections folded away with their round buttons, by key, kept between
    /// launches as Photos keeps its own. A television's sections don't fold.
    @AppStorage("albums.collapsedSections") private var collapsedSections = ""
    #endif

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

    var body: some View {
        Group {
            if let store {
                page(store)
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
        .placeDestination($pickedPlace, session: session, space: session.personalSpace)
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
        // And the counts, while you're looking at them. See `LiveCounts`.
        .modifier(LiveCounts(session: session) {
            await collections?.refreshIfChanged()
            await store?.refreshIfChanged()
        })
        // The covers and the top row stay as they are while you're here; what
        // the NAS sends meanwhile goes up once you've gone. See
        // `CollectionsStore.take`.
        .holdsCovers(store, collections)
    }

    /// The page, the same on every device: Photos' Collections, a section at a
    /// time.
    private func page(_ store: AlbumStore) -> some View {
        GeometryReader { proxy in
            let layout = CollectionsLayout(width: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: CollectionsLayout.sectionSpacing) {
                    let space = session.personalSpace
                    let found = collections?.page
                    if let space, let collections, let found {
                        memories(found, space: space, store: collections, layout: layout)
                        pinned(found, space: space, store: collections, layout: layout)
                        people(found, space: space, layout: layout)
                    }
                    albums(store, layout: layout)
                    shared(store, layout: layout)
                    if let space, let collections, let found {
                        trips(found, space: space, layout: layout)
                        occasions(found, space: space, layout: layout)
                        traditions(found, space: space, layout: layout)
                        mediaTypes(found, space: space, layout: layout)
                        utilities(found, space: space, store: collections, layout: layout)
                    }
                }
                .padding(.vertical, CollectionsLayout.pagePadding)
            }
            #if !os(macOS)
            // Asking to see what's new: it goes straight up, covers and all.
            .refreshable {
                await store.refresh(explicit: true)
                await collections?.refresh(explicit: true)
            }
            #endif
        }
    }

    // MARK: Sections

    #if !os(tvOS)
    private var collapsedKeys: Set<String> {
        Set(collapsedSections.split(separator: ",").map(String.init))
    }
    #endif

    private func isCollapsed(_ key: String) -> Bool {
        #if os(tvOS)
        return false
        #else
        return collapsedKeys.contains(key)
        #endif
    }

    /// Folds a section away, or brings it back. Nil on a television.
    private func toggle(_ key: String) -> (() -> Void)? {
        #if os(tvOS)
        return nil
        #else
        return {
            var keys = collapsedKeys
            if keys.remove(key) == nil { keys.insert(key) }
            withAnimation(.snappy(duration: 0.25)) {
                collapsedSections = keys.sorted().joined(separator: ",")
            }
        }
        #endif
    }

    /// A titled section. What's in it runs from one edge of the page to the
    /// other: a row that scrolls sideways insets its own cards, and everything
    /// else is held in by the margin where it's drawn.
    ///
    /// The title opens the section on a screen of its own, `destination`, or
    /// `route` for one pushed by value. See `AlbumsRoute`.
    private func section<Content: View>(
        _ key: String, _ title: String, note: String? = nil,
        destination: (() -> AnyView)? = nil, route: AlbumsRoute? = nil,
        layout: CollectionsLayout, @ViewBuilder content: () -> Content
    ) -> some View {
        let collapsed = isCollapsed(key)
        return VStack(alignment: .leading, spacing: CollectionsLayout.headerSpacing) {
            CollectionsSectionHeader(
                title: title, note: note, destination: destination, route: route,
                isCollapsed: collapsed, onToggle: toggle(key)
            )
            .padding(.horizontal, layout.margin)
            if !collapsed {
                content()
                    .transition(.opacity)
            }
        }
    }

    /// The cards the server picked for today, along the top: what's tied to
    /// today, a featured photo or two, and the day's highlights, each saying
    /// why it's there. A server from before the row sends only its first.
    ///
    /// Picked and ordered by the server, which also takes the first out of the
    /// sections below so the same place is never offered twice in one glance;
    /// see its `heroKey`. Absent on a library too young to have noticed
    /// anything.
    @ViewBuilder
    private func memories(
        _ found: CollectionsResponse, space: SpaceDTO, store: CollectionsStore,
        layout: CollectionsLayout
    ) -> some View {
        let cards = found.featured ?? found.hero.map { [$0] } ?? []
        if !cards.isEmpty {
            let size = layout.memorySize
            section(
                "memories", "Memories",
                destination: { AnyView(MemoriesView(session: session, space: space, store: store)) },
                layout: layout
            ) {
                CollectionsShelf(layout: layout) {
                    ForEach(cards, id: \.featuredID) { card in
                        MemoryCard(session: session, space: space, card: card, look: .hero(size)) {
                            naming = $0
                        }
                        // Room for the card's shadow, which the row would
                        // clip. It falls further below a card than above.
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
                .padding(.top, -12)
                .padding(.bottom, -24)
            }
        }
    }

    /// What somebody comes to the page for, whatever the library has noticed:
    /// Photos' pinned row, in Photos' order, with how much is in each. Never
    /// empty, so its title always opens it; see `PinnedCards`.
    private func pinned(
        _ found: CollectionsResponse, space: SpaceDTO, store: CollectionsStore,
        layout: CollectionsLayout
    ) -> some View {
        section(
            "pinned", "Pinned",
            destination: {
                AnyView(PinnedView(
                    session: session, space: space, store: store, placeTotal: $placeTotal
                ))
            },
            layout: layout
        ) {
            cardRow(layout, .small) {
                PinnedCards(
                    session: session, space: space, found: found, placeTotal: placeTotal,
                    side: layout.side(.small)
                ) { pickedPlace = $0 }
            }
        }
    }

    /// The people the NAS found in this library, the named first, along a row
    /// of faces. A library the NAS analyzes always has the section, saying
    /// what will be there until someone is; any other library, and a server
    /// that predates People, has none.
    @ViewBuilder
    private func people(
        _ found: CollectionsResponse, space: SpaceDTO, layout: CollectionsLayout
    ) -> some View {
        if let people = found.people {
            let side = layout.side(.small)
            section(
                "people", "People",
                destination: people.isEmpty ? nil : {
                    AnyView(PeopleListView(session: session, space: space, initial: people))
                },
                layout: layout
            ) {
                if people.isEmpty {
                    CollectionsEmptyCard(
                        symbol: "person.2", title: "No People Yet",
                        message: "As your NAS looks through your photos and videos, the "
                            + "people you photograph most appear here."
                    )
                    .padding(.horizontal, layout.margin)
                } else {
                    CollectionsShelf(layout: layout) {
                        ForEach(people) { person in
                            NavigationLink {
                                PersonView(session: session, space: space, person: person)
                            } label: {
                                PersonTile(
                                    session: session, spaceID: space.id, person: person, side: side
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Personal albums, and only those. New Album's "Personal" says this is
    /// where one goes, and the note under the title says who sees them.
    ///
    /// One row, as every other section has, with the rest behind the title.
    /// It used to lay out every album in the page's columns, so the page and
    /// the screen behind the › showed the same four, and he asked for a single
    /// row here and the whole set there (2026-11-25).
    private func albums(_ store: AlbumStore, layout: CollectionsLayout) -> some View {
        let albums = store.personal
        let side = layout.side(.medium)
        return section(
            "albums", "Albums", note: albums.isEmpty ? nil : "Only you can see these.",
            destination: albums.isEmpty ? nil : {
                AnyView(PersonalAlbumsView(session: session, store: store))
            },
            layout: layout
        ) {
            if !albums.isEmpty {
                cardRow(layout, .medium) {
                    ForEach(oneRow(albums, layout)) { album in
                        AlbumCell(session: session, album: album, store: store, side: side)
                    }
                }
            } else if store.hasLoaded {
                CollectionsEmptyCard.noAlbums(create: startAlbum)
                    .padding(.horizontal, layout.margin)
            }
        }
    }

    /// Everything shared, in one section: the albums shared with people, then
    /// each shared library you're in and the shared albums made in it.
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
    /// The same on a Mac. The libraries were left out there because the
    /// sidebar lists them too — and a library with no albums of its own then
    /// left the whole section empty, so the family's shared album was on the
    /// phone and nowhere on the Mac signed in to the same account. Photos keeps
    /// Shared Albums on its Albums page and in its sidebar both; so does this.
    private func shared(_ store: AlbumStore, layout: CollectionsLayout) -> some View {
        let cards = sharedCards(store)
        let side = layout.side(.medium)
        // No line saying who can see these. It said what "shared" already
        // says, under the one title on the page that says it.
        //
        // One row, with the rest behind the title, as Albums above it.
        return section(
            "shared", "Shared Albums", route: cards.isEmpty ? nil : .sharedAlbums,
            layout: layout
        ) {
            if !cards.isEmpty {
                cardRow(layout, .medium) {
                    ForEach(oneRow(cards, layout)) { card in
                        SharedCell(session: session, entry: card, store: store, side: side)
                    }
                }
            } else if store.hasLoaded {
                CollectionsEmptyCard.noSharedAlbums(start: startAlbum)
                    .padding(.horizontal, layout.margin)
            }
        }
    }

    /// As many of `items` as one row of the page holds: a sideways row's worth
    /// where rows scroll, and the cards that fit across anywhere wider. The
    /// same cut the curated sections make; the rest are behind the ›.
    private func oneRow<Item>(_ items: [Item], _ layout: CollectionsLayout) -> [Item] {
        Array(items.prefix(layout.scrollsSideways ? Self.shelfLimit : layout.across(.medium)))
    }

    /// Albums shared with people first, then each shared library and its
    /// albums. See `AlbumStore.sharedEntries`.
    private func sharedCards(_ store: AlbumStore) -> [AlbumStore.SharedEntry] {
        store.sharedEntries(libraries: session.sharedSpaces)
    }

    /// Time away from home, the trips the server chose. Before the occasions:
    /// two weeks away is a bigger thing than most single days.
    private func trips(
        _ found: CollectionsResponse, space: SpaceDTO, layout: CollectionsLayout
    ) -> some View {
        let chosen = found.wideTrips ?? found.trips
        return curated(
            "trips", "Trips",
            rows: layout.scrollsSideways ? chosen : Array(chosen.prefix(layout.across(.medium))),
            all: found.allTrips, seeAll: \.allTrips, space: space, layout: layout,
            empty: CollectionsEmptyCard(
                symbol: "suitcase", title: "No Trips Yet",
                message: "Time away from home appears here on its own, "
                    + "once there are photos from it."
            )
        )
    }

    /// What happened once. The years of what comes around every year are
    /// under Over the Years, and showing Christmas 2023 here too was the same
    /// photos twice on one page.
    private func occasions(
        _ found: CollectionsResponse, space: SpaceDTO, layout: CollectionsLayout
    ) -> some View {
        curated(
            "occasions", "Holidays & Occasions",
            rows: found.onceDays(
                limit: layout.scrollsSideways ? Self.shelfLimit : layout.across(.medium)
            ),
            all: found.onceOccasions, seeAll: \.onceOccasions, space: space, layout: layout,
            empty: found.traditions?.isEmpty == false
                ? CollectionsEmptyCard(
                    symbol: "calendar", title: "Nothing That Happened Once Yet",
                    message: "Weddings, graduations and the days you name "
                        + "appear here. What comes around every year is under "
                        + "Over the Years."
                )
                : CollectionsEmptyCard(
                    symbol: "calendar", title: "No Holidays or Occasions Yet",
                    message: "Holidays, birthdays and the days you name "
                        + "appear here as your library grows."
                )
        )
    }

    /// Trips, or holidays and occasions: the ones the server chose, as cards,
    /// with the title leading to every one of them.
    private func curated(
        _ key: String, _ title: String, rows: [CollectionSummary], all: [CollectionSummary]?,
        seeAll: KeyPath<CollectionsResponse, [CollectionSummary]?>, space: SpaceDTO,
        layout: CollectionsLayout, empty: CollectionsEmptyCard
    ) -> some View {
        // Whenever there's anything in the list, not only when it holds more
        // than the row: like every other section's, the title opens the
        // section on a screen of its own, with bigger cards. A server that
        // predates the list sends none, and then the title leads nowhere
        // rather than to an empty screen.
        var destination: (() -> AnyView)?
        if let all, !all.isEmpty, let collections {
            destination = {
                AnyView(CollectionListView(
                    session: session, space: space, title: title,
                    store: collections, list: seeAll
                ))
            }
        }
        let side = layout.side(.medium)
        return section(key, title, destination: destination, layout: layout) {
            if rows.isEmpty {
                empty
                    .padding(.horizontal, layout.margin)
            } else {
                cardRow(layout, .medium) {
                    ForEach(rows) { row in
                        CollectionCard(
                            session: session, space: space, collection: row, side: side,
                            detail: row.subtitle ?? itemsLine(row.count)
                        )
                        .nameable(row) { naming = $0 }
                    }
                }
            }
        }
    }

    /// What comes around every year, the soonest first: each Christmas
    /// together, a birthday, a day you named. Each opens on its years, and
    /// the title leads to every one of them.
    ///
    /// From a server that predates it there's no section at all, rather than
    /// one saying nothing is there.
    @ViewBuilder
    private func traditions(
        _ found: CollectionsResponse, space: SpaceDTO, layout: CollectionsLayout
    ) -> some View {
        if let traditions = found.traditions, let collections {
            let shown = Array(traditions.prefix(
                layout.scrollsSideways ? Self.shelfLimit : layout.across(.medium)
            ))
            let side = layout.side(.medium)
            section(
                "traditions", "Over the Years",
                destination: traditions.isEmpty ? nil : {
                    AnyView(TraditionListView(session: session, space: space, store: collections))
                },
                layout: layout
            ) {
                if shown.isEmpty {
                    CollectionsEmptyCard(
                        symbol: "calendar.badge.clock", title: "Nothing Over the Years Yet",
                        message: "Holidays and the days you mark every year gather here, "
                            + "each with all its years, once there are two years of them."
                    )
                    .padding(.horizontal, layout.margin)
                } else {
                    cardRow(layout, .medium) {
                        ForEach(shown) { tradition in
                            NavigationLink {
                                TraditionView(
                                    session: session, space: space, store: collections,
                                    tradition: tradition
                                )
                            } label: {
                                TraditionTile(tradition: tradition, side: side, loader: session.loader)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Every kind, each its own row with how many, as Photos lists them.
    ///
    /// The file-shaped things sit below everything that happened: they are a
    /// filter over what you already have, not a thing that happened.
    @ViewBuilder
    private func mediaTypes(
        _ found: CollectionsResponse, space: SpaceDTO, layout: CollectionsLayout
    ) -> some View {
        if !found.mediaTypes.isEmpty {
            section(
                "mediaTypes", "Media Types",
                destination: {
                    AnyView(MediaTypesView(session: session, space: space, types: found.mediaTypes))
                },
                layout: layout
            ) {
                pills(layout, count: found.mediaTypes.count) {
                    ForEach(found.mediaTypes) { type in
                        NavigationLink {
                            CollectionDetailView(session: session, space: space, collection: type)
                        } label: {
                            CollectionsPill(
                                title: type.title,
                                symbol: CollectionsPill.symbol(forMediaType: type.key),
                                count: type.count
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The tools: Recently Deleted always, at zero too, then what arrived
    /// lately and where it was taken. Never empty, so its title always opens
    /// them as cards.
    private func utilities(
        _ found: CollectionsResponse, space: SpaceDTO, store: CollectionsStore,
        layout: CollectionsLayout
    ) -> some View {
        let count = 1 + (found.recentlyAdded == nil ? 0 : 1) + (placeTotal > 0 ? 1 : 0)
        return section(
            "utilities", "Utilities",
            destination: {
                AnyView(UtilitiesView(
                    session: session, space: space, store: store, placeTotal: $placeTotal
                ))
            },
            layout: layout
        ) {
            pills(layout, count: count) {
                NavigationLink {
                    RecentlyDeletedView(session: session, space: space)
                } label: {
                    CollectionsPill(
                        title: "Recently Deleted", symbol: "trash",
                        count: found.recentlyDeleted?.count ?? 0
                    )
                }
                .buttonStyle(.plain)
                if let recent = found.recentlyAdded {
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: recent)
                    } label: {
                        CollectionsPill(title: recent.title, symbol: "clock", count: recent.count)
                    }
                    .buttonStyle(.plain)
                }
                if placeTotal > 0 {
                    NavigationLink {
                        placesList(space)
                    } label: {
                        CollectionsPill(title: "Places", symbol: "map", count: placeTotal)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Cards and rows

    /// How many cards a row that scrolls sideways holds before the rest are
    /// behind its title: as many as the server sends for a row.
    private static let shelfLimit = 12

    /// Every place the library knows, from Utilities' row. See `PlacesCard`.
    private func placesList(_ space: SpaceDTO) -> some View {
        AllPlacesView(session: session, space: space, total: placeTotal) { name in
            pickedPlace = name
        }
    }

    /// A section's cards along a row: one that scrolls sideways where the
    /// layout's rows do, and on a Mac a grid, which the caller keeps to a row
    /// where the rest are behind the title.
    @ViewBuilder
    private func cardRow<Content: View>(
        _ layout: CollectionsLayout, _ size: CollectionsLayout.Size,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if layout.scrollsSideways {
            let cards = content()
            CollectionsShelf(layout: layout) { cards }
        } else {
            cardGrid(layout, size, content: content)
        }
    }

    /// Cards in the page's columns, every one of them.
    private func cardGrid<Content: View>(
        _ layout: CollectionsLayout, _ size: CollectionsLayout.Size,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVGrid(
            columns: layout.columns(size), alignment: .leading, spacing: layout.gap,
            content: content
        )
        .padding(.horizontal, layout.margin)
    }

    /// `count` compact rows: in columns that scroll sideways on a phone, and
    /// as many columns as fit anywhere wider. See `CollectionsLayout.rowWidth`.
    @ViewBuilder
    private func pills<Content: View>(
        _ layout: CollectionsLayout, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        if let width = layout.rowWidth {
            let rows = content()
            ScrollView(.horizontal) {
                LazyHGrid(rows: layout.rowStack(count), spacing: layout.gap) {
                    Group { rows }
                        .frame(width: width)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, layout.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(.hidden)
        } else {
            LazyVGrid(
                columns: layout.rowColumns, alignment: .leading, spacing: layout.rowSpacing,
                content: content
            )
            .padding(.horizontal, layout.margin)
        }
    }

    /// New Album, from an empty section's button. A television's empty
    /// sections have none.
    private var startAlbum: (() -> Void)? {
        #if os(tvOS)
        return nil
        #else
        return { showCreate = true }
        #endif
    }
}

/// Brings a screen up to date a moment after this device changes a library:
/// a photo deleted or restored, an album's photos changed, an upload landing.
/// See `AppSession.libraryRevision`.
///
/// A grid used to learn of its own changes when its fifteen-second poll next
/// came round, or when it was next opened. Delete a photo from the viewer and
/// the viewer closed onto a grid that still had it.
///
/// Never while a photo is open over the screen. The way out of the viewer
/// flies the photo back into its tile, and a grid rebuilt underneath would
/// take the tile away mid-flight; this waits for the viewer to go. Changes
/// made while the screen was out of sight are caught up when it's back.
///
/// A modifier of its own so that only this reads the revision. Read in a
/// screen's body, every photo a backup committed would rebuild the screen.
struct FollowsOwnChanges: ViewModifier {
    let session: AppSession
    let refresh: @MainActor () async -> Void
    /// The revision this screen last caught up to. Nil until it first appears,
    /// when its own load is the catching up.
    @State private var seen: Int?

    private struct Watch: Equatable {
        let revision: Int
        let viewerOpen: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Watch(revision: session.libraryRevision, viewerOpen: Self.viewerOpen)) {
            guard let seen else {
                self.seen = session.libraryRevision
                return
            }
            guard seen != session.libraryRevision, !Self.viewerOpen else { return }
            // Twenty photos deleted at once, or a backup landing one after
            // another, settle first and are asked about once. Long enough,
            // too, for a photo flying home to land in its tile.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.seen = session.libraryRevision
            await refresh()
        }
    }

    private static var viewerOpen: Bool {
        #if os(iOS)
        !GridChrome.shared.openViewers.isEmpty
        #else
        false
        #endif
    }
}

/// Keeps a page's counts current for as long as it's on screen: the albums'
/// numbers, Media Types, Recently Deleted.
///
/// Two sources of change. This device's own (a photo trashed or restored, an
/// album changed, an upload landing) arrive as `AppSession.libraryRevision`,
/// and are asked about a moment after they happen, so a run of them is one
/// request. Everyone else's, and the NAS's (a backup landing from the phone's
/// background extension, a photo deleted on the iPad), show up in the
/// personal library's change log, read every fifteen seconds as the Photos
/// grid reads it: an unchanged library answers with an empty list, and only a
/// change sends the page's own heavier requests.
///
/// The first through `FollowsOwnChanges`, which every grid uses as well.
struct LiveCounts: ViewModifier {
    let session: AppSession
    let refresh: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .modifier(FollowsOwnChanges(session: session, refresh: refresh))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task(id: isVisible && scenePhase == .active) {
                guard isVisible, scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    if let space = session.personalSpace {
                        await session.timelineStore(for: space)?.refresh()
                    }
                    await refresh()
                }
            }
    }
}

extension CollectionSummary {
    /// Unique within the top row: the server never puts one set of photos in
    /// it twice, and the kind keeps two cards apart even if it did.
    fileprivate var featuredID: String { "\(kind.rawValue)/\(key)" }
}

/// One card on the Albums page: an album, or a shared library drawn as one,
/// with its name on the picture like every other card on the page.
private struct AlbumCard: View {
    let title: String
    let details: String
    let cover: CoverThumbnail?
    let side: CGFloat
    let loader: ThumbnailLoader?
    /// What stands in for the cover while there's none.
    var placeholder = "rectangle.stack"
    /// Marked in the corner: two people on anything shared.
    var badge: String?

    var body: some View {
        CollectionTile(title: title, detail: details, width: side, badge: badge) {
            CollectionCover(covers: cover.map { [$0] } ?? [], loader: loader, size: 512)
            .overlay {
                if cover == nil {
                    Image(systemName: placeholder)
                        .font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

extension AlbumCard {
    /// An album: its count, after who it's shared with if it is — its
    /// library's name, or its people.
    init(
        album: AlbumDTO, side: CGFloat, loader: ThumbnailLoader?, library: String?, me: UUID?
    ) {
        let count = itemsLine(album.itemCount)
        let with = album.isSharedWithPeople
            ? ShareWording.card(for: album, me: me) : library
        self.init(
            title: album.name, details: with.map { "\($0) · \(count)" } ?? count,
            cover: album.cover, side: side, loader: loader,
            placeholder: album.isSharedWithPeople ? "person.2" : "rectangle.stack",
            badge: with == nil ? nil : "person.2.fill"
        )
    }

    /// A shared library: who's in it and how much, its most recently added
    /// photo for a cover. Without a summary from the NAS, just who.
    init(library space: SpaceDTO, summary: SharedLibrarySummary?, side: CGFloat, loader: ThumbnailLoader?) {
        let members = summary?.memberCount ?? space.memberCount
        let people = ShareWording.people(count: members)
        self.init(
            title: space.name,
            details: summary.map { "\(people) · \(itemsLine($0.itemCount))" } ?? people,
            cover: summary?.cover, side: side, loader: loader,
            placeholder: "person.2", badge: "person.2.fill"
        )
    }
}

// MARK: - Cards the page and its sections' screens share

/// A collection as a card, opening its photos: a pinned collection, a trip,
/// an occasion. The same card on the page's rows and on the screens their
/// titles open.
struct CollectionCard: View {
    let session: AppSession
    let space: SpaceDTO
    let collection: CollectionSummary
    let side: CGFloat
    var detail: String?
    /// See `CollectionTile.badge`.
    var badge: String?

    var body: some View {
        NavigationLink {
            CollectionDetailView(session: session, space: space, collection: collection)
        } label: {
            CollectionTile(title: collection.title, detail: detail, width: side, badge: badge) {
                CollectionCover(covers: collection.covers, loader: session.loader, size: 512)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One of the memories, opening its photos and saying why it's there: on the
/// page's top row and on Memories' own screen.
struct MemoryCard: View {
    /// How big, and so which card.
    enum Look {
        /// The page's top row: the big card, sized by the page
        /// (`CollectionsLayout.memorySize`).
        case hero(CGSize)
        /// Memories' own screen: every other card, `side` points square, with
        /// the big card's reason over its name. The big card's own type at
        /// two across a phone covered most of its picture and cut its dates
        /// off.
        case tile(side: CGFloat)
    }

    let session: AppSession
    let space: SpaceDTO
    let card: CollectionSummary
    let look: Look
    /// "Name This Day", from a long press. See `nameable`.
    let onName: (CollectionSummary) -> Void

    var body: some View {
        NavigationLink {
            CollectionDetailView(session: session, space: space, collection: card)
        } label: {
            switch look {
            case .hero(let size):
                CollectionHeroCard(
                    collection: card, loader: session.loader, width: size.width,
                    height: size.height
                )
            case .tile(let side):
                CollectionTile(
                    title: card.title, kicker: card.kickerLine,
                    detail: card.subtitle ?? itemsLine(card.count), width: side
                ) {
                    CollectionCover(covers: card.covers, loader: session.loader, size: 512)
                }
            }
        }
        .buttonStyle(.plain)
        .nameable(card, onName: onName)
    }
}

/// Every place the library knows, Search's own list: a way in by *where*,
/// which for an old library is often the only way in somebody has. A place
/// picked there opens as a screen of its own; see `placeDestination`.
struct PlacesCard: View {
    let session: AppSession
    let space: SpaceDTO
    let total: Int
    let side: CGFloat
    let onPick: (String) -> Void

    var body: some View {
        NavigationLink {
            AllPlacesView(session: session, space: space, total: total, onPick: onPick)
        } label: {
            CollectionTile(
                title: "Places",
                detail: total == 1 ? "1 place" : "\(total.formatted()) places",
                width: side
            ) {
                SymbolCover(
                    symbol: "map.fill",
                    colors: [Color(red: 0.2, green: 0.55, blue: 0.55),
                             Color(red: 0.08, green: 0.25, blue: 0.38)]
                )
            }
        }
        .buttonStyle(.plain)
    }
}

/// What was removed and can still come back, as a card.
struct RecentlyDeletedCard: View {
    let session: AppSession
    let space: SpaceDTO
    let count: Int
    let side: CGFloat

    var body: some View {
        NavigationLink {
            RecentlyDeletedView(session: session, space: space)
        } label: {
            CollectionTile(title: "Recently Deleted", detail: itemsLine(count), width: side) {
                SymbolCover(symbol: "trash", colors: [Color(white: 0.45), Color(white: 0.22)])
            }
        }
        .buttonStyle(.plain)
    }
}

/// What's pinned, as cards, in Photos' order: Recently Deleted, then
/// Favorites, Recently Added, Videos and Screenshots, and Places. The page's
/// row and Pinned's own screen draw the same cards from here, each at its own
/// size.
///
/// Recently Deleted first, as Photos puts it, so it's in view without
/// scrolling the row to its end (his word, 2026-11-26). It was last.
///
/// Recently Deleted is always here, at zero too. The NAS leaves its card out
/// when nothing is in it, and a card that only appears once you've deleted
/// something is a place nobody knows to look until they need it.
struct PinnedCards: View {
    let session: AppSession
    let space: SpaceDTO
    let found: CollectionsResponse
    /// How many places the library knows. None, and there's no Places card.
    let placeTotal: Int
    let side: CGFloat
    /// A place picked from Places' list.
    let onPickPlace: (String) -> Void

    /// Videos and screenshots, the kinds Photos pins.
    private var kinds: [CollectionSummary] {
        ["video", "screenshot"].compactMap { key in
            found.mediaTypes.first { $0.key == key }
        }
    }

    var body: some View {
        RecentlyDeletedCard(
            session: session, space: space, count: found.recentlyDeleted?.count ?? 0, side: side
        )
        if let favorites = found.favorites {
            CollectionCard(
                session: session, space: space, collection: favorites, side: side,
                detail: itemsLine(favorites.count), badge: "heart.fill"
            )
        }
        if let recent = found.recentlyAdded {
            CollectionCard(
                session: session, space: space, collection: recent, side: side,
                detail: itemsLine(recent.count)
            )
        }
        ForEach(kinds) { kind in
            CollectionCard(
                session: session, space: space, collection: kind, side: side,
                detail: itemsLine(kind.count)
            )
        }
        if placeTotal > 0 {
            PlacesCard(
                session: session, space: space, total: placeTotal, side: side, onPick: onPickPlace
            )
        }
    }
}

/// An album as a card, opening it: the same card and the same long press on
/// the Albums page and on the screens its sections open.
///
/// An album shared with people opens the way a shared library does, as a
/// timeline of its own space: the same route, the same screen, whether it's
/// reached from here, the Mac's sidebar or a notification. Yours alone and a
/// library's albums keep the album grid.
struct AlbumCell: View {
    let session: AppSession
    let album: AlbumDTO
    let store: AlbumStore
    let side: CGFloat

    /// Whether "Delete Album?" is up. Deleting used to happen on the menu tap
    /// itself, and an album somebody built by hand was one slip away from
    /// gone. Each card asks for itself, so the page and the screens a section
    /// opens ask the same way without sharing anything.
    @State private var confirmingDelete = false

    var body: some View {
        let library = album.libraryName(in: session)
        let card = AlbumCard(
            album: album, side: side, loader: session.loader, library: library,
            me: session.user?.id
        )
        Group {
            if let spaceID = album.ownSpace?.id {
                NavigationLink(
                    value: AlbumsRoute.shared(SharedAlbumRoute(spaceID: spaceID, albumID: album.id))
                ) {
                    card
                }
            } else {
                NavigationLink {
                    AlbumDetailView(session: session, album: album, store: store)
                } label: {
                    card
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if album.mayManage {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete Album", systemImage: "trash")
                }
            }
        }
        // On the card, not the page: where the question appears as a
        // popover, it points at the album it's asking about.
        .confirmationDialog(
            "Delete “\(album.name)”?", isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                Task { await store.delete(album) }
            }
        } message: {
            Text(album.deletionMessage(library: library))
        }
    }
}

/// A shared library as an album card, the same as the albums made in it: its
/// most recently added photo for a cover, and who's in it and how much. Opens
/// the whole library.
struct LibraryCell: View {
    let session: AppSession
    let space: SpaceDTO
    let store: AlbumStore
    let side: CGFloat

    var body: some View {
        NavigationLink(value: AlbumsRoute.shared(SharedAlbumRoute(spaceID: space.id))) {
            AlbumCard(
                library: space, summary: store.libraries.first { $0.id == space.id },
                side: side, loader: session.loader
            )
        }
        .buttonStyle(.plain)
    }
}

/// One card under Shared Albums: a whole shared library, or an album.
struct SharedCell: View {
    let session: AppSession
    let entry: AlbumStore.SharedEntry
    let store: AlbumStore
    let side: CGFloat

    var body: some View {
        switch entry {
        case .library(let space):
            LibraryCell(session: session, space: space, store: store, side: side)
        case .album(let album):
            AlbumCell(session: session, album: album, store: store, side: side)
        }
    }
}

extension AlbumDTO {
    /// The shared library a family album is in, by name.
    @MainActor
    func libraryName(in session: AppSession) -> String? {
        guard let spaceID else { return nil }
        return session.sharedSpaces.first { $0.id == spaceID }?.name
    }
}

extension CollectionsEmptyCard {
    /// Albums with none in it yet. `create` is New Album, where there's a way
    /// to it from here.
    static func noAlbums(create: (() -> Void)?) -> CollectionsEmptyCard {
        CollectionsEmptyCard(
            symbol: "rectangle.stack", title: "No Albums Yet",
            message: "Make an album to keep photos together. Only you will see it.",
            actionTitle: "Create", action: create
        )
    }

    /// Shared Albums with none in it yet. `start` is New Album, where there's
    /// a way to it from here.
    static func noSharedAlbums(start: (() -> Void)?) -> CollectionsEmptyCard {
        CollectionsEmptyCard(
            symbol: "person.2", title: "No Shared Albums Yet",
            message: "Share photos and videos with just the people you choose, "
                + "and let them add their own.",
            actionTitle: "Start Sharing", action: start
        )
    }
}

extension CollectionSummary {
    /// Everything from one place, whenever it was: what a place picked from
    /// All Places opens. `.revisit` is the kind that means exactly this, and
    /// it's already handled end to end.
    static func place(_ name: String) -> CollectionSummary {
        CollectionSummary(
            kind: .revisit, key: name, title: name, subtitle: nil, count: 0, coverAssetIDs: []
        )
    }
}

extension View {
    /// Opens the place picked from All Places as a screen of its own. Put on
    /// the screen the Places card is on, never inside its grid: a destination
    /// in a lazy container is gone once the card scrolls away.
    func placeDestination(
        _ picked: Binding<String?>, session: AppSession, space: SpaceDTO?
    ) -> some View {
        navigationDestination(item: picked) { place in
            if let space {
                CollectionDetailView(session: session, space: space, collection: .place(place))
            }
        }
    }
}

// MARK: - Sections on screens of their own

// What the › after a section's title opens, for the sections that had no list
// of their own. Each draws the section's own cards (above) in
// `CollectionsSectionScreen`'s grid, from the page's stores, read in its own
// body: what the page shows changes under a screen pushed over it, and a copy
// taken when the › was tapped would go on showing yesterday's counts.

/// Every card the NAS picked for today, each saying why it's there: what
/// Memories' title opens.
///
/// The row holds still while either is on screen (`CollectionsStore.take`),
/// so these are the cards just swiped past, in the same order.
struct MemoriesView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore

    @State private var naming: CollectionSummary?

    var body: some View {
        let cards = store.page.map { page in page.featured ?? page.hero.map { [$0] } ?? [] } ?? []
        CollectionsSectionScreen(title: "Memories") { side in
            ForEach(cards, id: \.featuredID) { card in
                MemoryCard(
                    session: session, space: space, card: card, look: .tile(side: side)
                ) { naming = $0 }
            }
        }
        #if !os(tvOS)
        .sheet(item: $naming) { collection in
            NameOccasionSheet(
                session: session, spaceID: space.id, collection: collection
            ) { changed in
                naming = nil
                // The server decides what a day ends up called. See the
                // page's own sheet.
                if changed { Task { await store.refresh() } }
            }
        }
        #endif
        .keepsUp(with: store, session: session)
    }
}

/// Everything pinned, as cards: what Pinned's title opens.
struct PinnedView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore
    /// How many places the library knows, as the page has it now.
    @Binding var placeTotal: Int

    /// The place picked from Places, pushed as its own screen.
    @State private var pickedPlace: String?

    var body: some View {
        let found = store.page
        CollectionsSectionScreen(title: "Pinned") { side in
            if let found {
                PinnedCards(
                    session: session, space: space, found: found, placeTotal: placeTotal,
                    side: side
                ) { pickedPlace = $0 }
            }
        }
        .placeDestination($pickedPlace, session: session, space: space)
        .keepsUp(with: store, session: session)
    }
}

/// Every album of your own: what Albums' title opens. The same cards as the
/// page's, opening the same way, with the same long press.
struct PersonalAlbumsView: View {
    @Bindable var session: AppSession
    let store: AlbumStore

    var body: some View {
        let albums = store.personal
        CollectionsSectionScreen(
            title: "Albums", empty: albums.isEmpty ? .noAlbums(create: nil) : nil
        ) { side in
            ForEach(albums) { album in
                AlbumCell(session: session, album: album, store: store, side: side)
            }
        }
        .keepsUp(with: store, session: session)
    }
}

/// Everything shared, in the page's order: what Shared Albums' title opens.
/// See `AlbumStore.sharedEntries`.
///
/// Pushed by value, `AlbumsRoute.sharedAlbums`, from where the Albums tab's
/// path is kept (`RootTabView`, and `MacRootView` on a Mac): its cards push
/// shared albums by value, which only lands on top from a screen that's in
/// the path itself.
struct SharedAlbumsView: View {
    @Bindable var session: AppSession
    let store: AlbumStore

    var body: some View {
        let entries = store.sharedEntries(libraries: session.sharedSpaces)
        CollectionsSectionScreen(
            title: "Shared Albums", empty: entries.isEmpty ? .noSharedAlbums(start: nil) : nil
        ) { side in
            ForEach(entries) { entry in
                SharedCell(session: session, entry: entry, store: store, side: side)
            }
        }
        .keepsUp(with: store, session: session)
    }
}

/// The tools as cards, in the row's order: Recently Deleted always, at zero
/// too, then what arrived lately and where it was taken. What Utilities'
/// title opens. The same cards as Pinned's, symbols and all.
struct UtilitiesView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let store: CollectionsStore
    /// How many places the library knows, as the page has it now.
    @Binding var placeTotal: Int

    /// The place picked from Places, pushed as its own screen.
    @State private var pickedPlace: String?

    var body: some View {
        let found = store.page
        CollectionsSectionScreen(title: "Utilities") { side in
            RecentlyDeletedCard(
                session: session, space: space, count: found?.recentlyDeleted?.count ?? 0,
                side: side
            )
            if let recent = found?.recentlyAdded {
                CollectionCard(
                    session: session, space: space, collection: recent, side: side,
                    detail: itemsLine(recent.count)
                )
            }
            if placeTotal > 0 {
                PlacesCard(session: session, space: space, total: placeTotal, side: side) {
                    pickedPlace = $0
                }
            }
        }
        .placeDestination($pickedPlace, session: session, space: space)
        .keepsUp(with: store, session: session)
    }
}

extension View {
    /// What a screen a section's title opens does to keep up, as the page
    /// does: asks again on arriving if what it shows has gone stale, follows
    /// changes while it's up (`LiveCounts`), and holds its covers still with
    /// the page's (`HoldsCovers`). Nothing on it changes in front of you that
    /// you didn't change yourself.
    fileprivate func keepsUp(with store: CollectionsStore, session: AppSession) -> some View {
        onAppear { Task { await store.refreshIfStale() } }
            .modifier(LiveCounts(session: session) { await store.refreshIfChanged() })
            .holdsCovers(store)
    }

    /// The same, for a screen of albums.
    fileprivate func keepsUp(with store: AlbumStore, session: AppSession) -> some View {
        onAppear { Task { await store.refreshIfStale() } }
            .modifier(LiveCounts(session: session) { await store.refreshIfChanged() })
            .holdsCovers(store)
    }
}

/// An album named in New Album from Add to Album, made once Add is pressed.
struct AlbumDraft: Identifiable, Hashable {
    let id = UUID()
    let name: String
    /// The shared library it goes in, on a NAS without albums shared with
    /// people.
    let spaceID: UUID?
    let libraryName: String?
    /// Who it's shared with. Empty, and it's yours alone.
    let memberIDs: [UUID]
    /// "Just you", "3 people", or the library's name, for its row.
    let audience: String

    var isShared: Bool { spaceID != nil || !memberIDs.isEmpty }
}

/// Making an album: a name, and who to share it with.
///
/// Nobody, and it's yours alone, under Albums. Anyone, and it's shared with
/// them, under Shared Albums: only the people in it see it, and each of them
/// can add to it. The note under the list says which as you pick, so nobody has
/// to guess where it went. Who's in it can change later, from Edit.
///
/// A NAS from before albums were shared with people gets the choice it always
/// had: Personal, or Shared into a library.
struct NewAlbumSheet: View {
    @Bindable var session: AppSession
    let store: AlbumStore
    /// Photos to start it with, when it's made from a selection.
    var spaceAssetIDs: [UUID] = []
    let onDone: (AlbumDTO?) -> Void
    /// From Add to Album: told the name and who it's shared with, and nothing
    /// is made yet. Add to Album makes it, with everything else picked, once
    /// Add is pressed. The button says "Done" then, not "Create".
    var onDraft: ((AlbumDraft) -> Void)?

    enum Kind: Hashable { case personal, shared }

    @State private var name = ""
    /// Everyone it could be shared with: the household, without you. Nil
    /// until it's known.
    @State private var household: [UserDTO]?
    @State private var householdFailed = false
    @State private var picked: Set<UUID> = []
    @State private var kind = Kind.personal
    /// Which shared library, when there's more than one to choose from.
    @State private var library: UUID?
    @State private var isCreating = false

    private var sharesWithPeople: Bool {
        session.supports(ServerCapability.peopleAlbums) || store.supportsPeople
    }

    /// The shared libraries a shared album can go in, on a NAS that only has
    /// those: the ones you can add to.
    private var libraries: [SpaceDTO] {
        guard store.supportsFamily, !sharesWithPeople else { return [] }
        return session.sharedSpaces.filter { $0.role != .viewer }
    }

    /// The library a shared album would go in: the one picked, or the only one.
    private var chosen: SpaceDTO? {
        guard kind == .shared, !sharesWithPeople else { return nil }
        return libraries.first { $0.id == library } ?? libraries.first
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The example as the field's placeholder, not its label:
                    // a Mac's form draws a label beside the field, and it sat
                    // out past the sheet's edge.
                    TextField("Name", text: $name, prompt: Text("Iceland 2012"))
                        .labelsHidden()
                } header: {
                    Text("Name")
                }
                if sharesWithPeople {
                    SharePeopleSection(
                        people: household, failed: householdFailed, picked: $picked
                    )
                } else if libraries.isEmpty {
                    Section {
                    } footer: {
                        Text(ShareWording.note(for: []))
                    }
                } else {
                    librarySection
                }
            }
            // The look of Edit and Add to Album beside it, rather than a
            // Mac's settings-pane form of push buttons.
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Opened before the app has heard from the NAS, the choice would
            // be missing and the album made personal by default. Asking here
            // brings it in as soon as the NAS answers.
            .task {
                await session.loadCapabilities()
                if !store.supportsFamily { await store.refresh() }
                await loadHousehold()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(onDraft == nil ? "Create" : "Done") {
                        let members = sharesWithPeople ? Array(picked) : []
                        if let onDraft {
                            onDraft(AlbumDraft(
                                name: trimmed, spaceID: chosen?.id,
                                libraryName: chosen?.name, memberIDs: members,
                                audience: chosen.map { "In \($0.name)" }
                                    ?? ShareWording.people(count: members.count + 1)
                            ))
                            return
                        }
                        isCreating = true
                        Task {
                            let album = await store.create(
                                name: trimmed, spaceID: chosen?.id,
                                memberIDs: members,
                                spaceAssetIDs: spaceAssetIDs
                            )
                            isCreating = false
                            onDone(album)
                        }
                    }
                    .disabled(trimmed.isEmpty || isCreating)
                }
            }
        }
        .macSheetSize()
    }

    /// Personal or a shared library, for a NAS without albums shared with
    /// people.
    private var librarySection: some View {
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
            Text(chosen.map(Self.libraryNote) ?? ShareWording.note(for: []))
        }
    }

    private func loadHousehold() async {
        guard sharesWithPeople, household == nil else { return }
        if let people = await ShareWording.household(session) {
            household = people
        } else {
            householdFailed = true
        }
    }

    static func libraryNote(_ space: SpaceDTO) -> String {
        "Everyone in \(space.name) can see a shared album and add to it. You'll find it "
            + "under Shared Albums."
    }
}

/// Everyone on this NAS an album could be shared with, a checkmark against
/// each one it is. Under it, who will see the album, and where it will be.
struct SharePeopleSection: View {
    /// Nil while it's being asked for.
    let people: [UserDTO]?
    var failed = false
    @Binding var picked: Set<UUID>

    var body: some View {
        Section {
            if let people {
                if people.isEmpty {
                    Text("No one else has an account on this NAS yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(people) { person in
                    Button {
                        if picked.contains(person.id) {
                            picked.remove(person.id)
                        } else {
                            picked.insert(person.id)
                        }
                    } label: {
                        HStack {
                            // `Color`, not the hierarchical styles: inside a
                            // button those resolve against the accent tint.
                            Text(person.displayName)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if picked.contains(person.id) {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // A row with a checkmark, as on the phone, not a push
                    // button per person.
                    #if os(macOS)
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityAddTraits(picked.contains(person.id) ? .isSelected : [])
                }
            } else if failed {
                Text("Couldn't load who's on this NAS. Try again in a moment.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Share With")
        } footer: {
            Text(ShareWording.note(for: (people ?? []).filter { picked.contains($0.id) }))
        }
    }
}

/// How the app says who an album is shared with, the same everywhere it says it.
enum ShareWording {
    /// "Jane", "Jane and Mover", "Jane, Mover, and Sam", "Jane, Mover, and 3
    /// others".
    static func names(_ people: [UserDTO]) -> String {
        let names = people.map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]), and \(names[2])"
        default: return "\(names[0]), \(names[1]), and \(names.count - 2) others"
        }
    }

    /// What the people picker says under it.
    static func note(for picked: [UserDTO]) -> String {
        guard !picked.isEmpty else {
            return "Only you can see this album. You'll find it under Albums."
        }
        return "\(names(picked)) can see this album and add to it. You'll find it "
            + "under Shared Albums."
    }

    /// The line on an album's card: how many people are in it, you included —
    /// "4 people", the way a shared library's card counts its members, so the
    /// two cards side by side under Shared Albums read alike. It named them
    /// ("With Lorie and 2 others"), which made one card count people and the
    /// next one list them.
    static func card(for album: AlbumDTO, me: UUID?) -> String {
        people(count: (album.people?.count ?? 0) + 1)
    }

    /// "4 people", or "Just you" — for an album and a library alike.
    static func people(count: Int) -> String {
        count <= 1 ? "Just you" : "\(count) people"
    }

    /// Everyone an album could be shared with: the household, without you.
    /// Nil when the NAS couldn't be asked.
    @MainActor
    static func household(_ session: AppSession) async -> [UserDTO]? {
        guard let client = session.client,
              let users = try? await client.household().users else { return nil }
        return users.filter { $0.id != session.user?.id }
    }
}

/// An album's settings, from the Edit button in its own grid, laid out the way
/// a shared library's are (`SpaceMembersView`): its name, who's in it and what
/// each added, people to add, and deleting or leaving it — one Done, and each
/// change made as it's chosen. The two sheets were different screens for the
/// same question, a Form with a checklist and Save beside a list with Done,
/// and an album shared with the family should feel no different to edit than
/// the family's library.
///
/// Who's in it and their counts come from the album's own space, the answer a
/// library's Edit draws from. Changing who's in it goes through the album
/// (`AlbumStore.setPeople`), never the library calls: sharing an album copies
/// its photos and tells its people, which adding someone to a space doesn't.
struct AlbumSettingsSheet: View {
    @Bindable var session: AppSession
    let album: AlbumDTO
    let store: AlbumStore
    /// The shared library a family album is in, by name.
    let library: String?
    /// Told when the album is gone for you — deleted, or left — before
    /// `onDone`, so the screen that was showing it can leave once these close.
    let onDeleted: () -> Void
    let onDone: () -> Void

    @State private var name: String
    @State private var household: [UserDTO]?
    @State private var householdFailed = false
    /// Who's in it and what each added. Nil until the NAS answers.
    @State private var roster: [SpaceMemberDTO]?
    @State private var rosterFailed = false
    /// Who you've blocked, for the ⋯ beside each person. Nil where blocking
    /// isn't offered.
    @State private var blocked: Set<UUID>?
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var confirmingAdd: UserDTO?
    @State private var confirmingRemoval: SpaceMemberDTO?
    @State private var confirmingBlock: SpaceMemberDTO?
    /// Photos reported in an album you shared, waiting on you.
    @State private var reports: [ContentReportDTO] = []
    @State private var failure: String?

    init(
        session: AppSession, album: AlbumDTO, store: AlbumStore, library: String?,
        onDeleted: @escaping () -> Void = {}, onDone: @escaping () -> Void
    ) {
        self.session = session
        self.album = album
        self.store = store
        self.library = library
        self.onDeleted = onDeleted
        self.onDone = onDone
        _name = State(initialValue: album.name)
    }

    /// The album as the list has it now. People added or taken out here
    /// change it, and `album` is how it was when the sheet opened.
    private var current: AlbumDTO { store.albums.first { $0.id == album.id } ?? album }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether who it's shared with is yours to choose here: an album you
    /// manage that isn't a library's, on a NAS that shares albums with people.
    private var choosesPeople: Bool {
        current.mayManage && !current.isLibraryAlbum
            && (session.supports(ServerCapability.peopleAlbums) || store.supportsPeople)
    }

    private var nameChanged: Bool { !trimmed.isEmpty && trimmed != current.name }

    /// Everyone it's shared with but you.
    private var people: [UserDTO] { current.people ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if current.mayManage && !reports.isEmpty { reportsSection }
                if current.mayManage { nameSection }
                if !current.isLibraryAlbum { membersSection }
                if choosesPeople { addSection }
                endSection
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(current.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: finish).disabled(isSaving)
                }
            }
            .task { await load() }
            // Again when sharing gives it a space of its own, or takes it away.
            .task(id: current.spaceID) { await loadRoster() }
            .confirmationDialog(
                "Delete “\(current.name)”?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete Album", role: .destructive) {
                    Task {
                        if await store.delete(current) {
                            onDeleted()
                            onDone()
                        } else {
                            failure = store.lastError ?? "That didn't delete. Try again."
                        }
                    }
                }
            } message: {
                Text(current.deletionMessage(library: library))
            }
            .confirmationDialog(
                "Leave “\(current.name)”?", isPresented: $confirmLeave, titleVisibility: .visible
            ) {
                Button("Leave Album", role: .destructive) {
                    Task {
                        if await store.leave(current) {
                            onDeleted()
                            onDone()
                        } else {
                            failure = store.lastError ?? "That didn't work. Try again."
                        }
                    }
                }
            } message: {
                Text("You won't see it anymore. Photos you added stay in it for the others.")
            }
            // Asked, as a library asks: it opens the whole album to them,
            // what's already in it as well as what comes next.
            .confirmationDialog(
                addTitle, isPresented: .init(
                    get: { confirmingAdd != nil },
                    set: { if !$0 { confirmingAdd = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(current.isSharedWithPeople ? "Add" : "Share") {
                    guard let person = confirmingAdd else { return }
                    confirmingAdd = nil
                    setPeople(people.map(\.id) + [person.id])
                }
                Button("Cancel", role: .cancel) { confirmingAdd = nil }
            } message: {
                Text(addMessage)
            }
            .confirmationDialog(
                "Remove \(confirmingRemoval?.user.displayName ?? "")?",
                isPresented: .init(
                    get: { confirmingRemoval != nil },
                    set: { if !$0 { confirmingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    guard let target = confirmingRemoval else { return }
                    confirmingRemoval = nil
                    remove(target)
                }
                Button("Cancel", role: .cancel) { confirmingRemoval = nil }
            } message: {
                Text(removalMessage)
            }
            .confirmationDialog(
                "Block \(confirmingBlock?.user.displayName ?? "")?",
                isPresented: .init(
                    get: { confirmingBlock != nil },
                    set: { if !$0 { confirmingBlock = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    guard let target = confirmingBlock else { return }
                    confirmingBlock = nil
                    Task { await setBlocked(true, target.user.id) }
                }
                Button("Cancel", role: .cancel) { confirmingBlock = nil }
            } message: {
                Text(BlockWording.consequences)
            }
        }
        .macSheetSize()
        .onDisappear(perform: keepTypedName)
    }

    /// A name typed and not yet saved, saved as the sheet goes, however it
    /// goes. Done and Return saved it; swiping the sheet away threw it out
    /// without a word, and the album kept its old name on every device.
    /// Not for an album that's gone — deleted or left from here.
    private func keepTypedName() {
        guard current.mayManage, nameChanged,
              store.albums.contains(where: { $0.id == album.id }) else { return }
        let target = current
        let newName = trimmed
        Task { await store.rename(target, to: newName) }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            #if os(tvOS)
            Text(name)
            #else
            TextField("Name", text: $name)
                .submitLabel(.done)
                .onSubmit { Task { _ = await rename() } }
            #endif
        }
    }

    /// Everyone in it, you included, with what each added — the rows a
    /// library's Edit draws, and the same ⋯ beside each: Remove for the
    /// album's maker, Block for anyone. Yours alone, it's just you.
    private var membersSection: some View {
        Section {
            if let roster {
                ForEach(roster) { member in
                    let isYou = member.user.id == session.user?.id
                    MemberRow(
                        member: member,
                        isYou: isYou,
                        canManage: current.mayManage && member.role != .owner,
                        isBlocked: isYou ? nil : blocked.map { $0.contains(member.user.id) },
                        onRole: nil,
                        onRemove: { confirmingRemoval = member },
                        onBlock: { block in
                            if block {
                                confirmingBlock = member
                            } else {
                                Task { await setBlocked(false, member.user.id) }
                            }
                        }
                    )
                }
            } else if rosterFailed {
                Text("Couldn't load who's in it. Try again in a moment.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Members")
        } footer: {
            Text(membersFooter)
        }
    }

    private var membersFooter: String {
        guard current.isSharedWithPeople else {
            return "Only you can see this album. It's under Albums."
        }
        if current.mayManage { return "Everyone here can see this album and add to it." }
        return "Everyone here can see this album and add to it. Only "
            + "\(current.owner?.displayName ?? "the person who made it") can change who's in it."
    }

    /// Everyone else on the NAS, to bring in, the way a library's Edit lists
    /// them. Always there for the album's maker, saying why when there's no
    /// one to add.
    private var addSection: some View {
        let inIt = Set(people.map(\.id))
        let candidates = (household ?? []).filter { !inIt.contains($0.id) }
        return Section {
            if householdFailed {
                Text("Couldn't load who's on this NAS. Try again in a moment.")
                    .foregroundStyle(.secondary)
            } else if household == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if candidates.isEmpty {
                Text(household?.isEmpty == false
                    ? "Everyone with an account on this NAS is already here."
                    : "No one else has an account on this NAS yet. Once someone signs in "
                        + "to FrameStation on their own device, they'll be here to add.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { user in
                Button {
                    confirmingAdd = user
                } label: {
                    HStack {
                        // `Color`, not the hierarchical styles: inside a button
                        // those resolve against the accent tint.
                        Text(user.displayName)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(isSaving)
                .accessibilityLabel("Add \(user.displayName)")
            }
        } header: {
            Text("Add People")
        } footer: {
            if !candidates.isEmpty {
                Text("They'll see everything here and can add their own.")
            }
        }
    }

    /// Deleting it, for its maker; leaving it, for anyone it was shared with.
    @ViewBuilder
    private var endSection: some View {
        if current.mayManage {
            Section {
                Button("Delete Album", role: .destructive) { confirmDelete = true }
            } footer: {
                if current.isLibraryAlbum {
                    Text("Everyone in \(library ?? "its shared library") can see this album. "
                        + "It's under Shared Albums.")
                }
            }
        } else if current.isSharedWithPeople {
            Section {
                Button("Leave Album", role: .destructive) { confirmLeave = true }
            }
        } else {
            Section {
            } footer: {
                Text("Only the person who made this album, or the owner of "
                    + "\(library ?? "its shared library"), can rename or delete it.")
            }
        }
    }

    /// Photos reported in an album you shared. The same review a library's
    /// owner gets, in the album's own settings.
    private var reportsSection: some View {
        Section {
            ForEach(reports) { report in
                ReportedPhotoRow(
                    report: report, loader: session.loader,
                    onRemove: { resolve(report, removing: true) },
                    onKeep: { resolve(report, removing: false) }
                )
            }
        } header: {
            Text("Reported")
        } footer: {
            Text("Remove takes it out of this album for everyone. Keep leaves it here, "
                + "still hidden from whoever reported it. Who reported it isn't shown.")
        }
    }

    // MARK: - Wording

    private var addTitle: String {
        let person = confirmingAdd?.displayName ?? ""
        return current.isSharedWithPeople
            ? "Add \(person) to \(current.name)?"
            : "Share “\(current.name)” with \(person)?"
    }

    private var addMessage: String {
        guard current.isSharedWithPeople else {
            return "\(confirmingAdd?.displayName ?? "They") will see its "
                + "\(itemsLine(current.itemCount)) and can add their own. "
                + "It moves to Shared Albums."
        }
        return "They'll see everything in \(current.name), including what's already here, "
            + "and can add their own."
    }

    /// What taking this person out does. The last one out makes it yours
    /// alone again, which is said first, as unsharing always was.
    private var removalMessage: String {
        guard let member = confirmingRemoval else { return "" }
        if people.count <= 1 {
            return "They won't see it anymore. It will be yours alone, under Albums."
        }
        let base = "They lose access to this album."
        let count = member.contributedCount
        guard count > 0 else { return base }
        return base + " The \(count) item\(count == 1 ? "" : "s") they added stay in it."
    }

    // MARK: - Loading and changes

    private func load() async {
        await session.loadCapabilities()
        if choosesPeople, household == nil {
            if let everyone = await ShareWording.household(session) {
                household = everyone
            } else {
                householdFailed = true
            }
        }
        guard session.supports(ServerCapability.reportAndBlock),
              let client = session.client else { return }
        if current.mayManage, current.isSharedWithPeople, let spaceID = current.spaceID,
           let open = try? await client.openReports(spaceID: spaceID) {
            reports = open
        }
        if let list = try? await client.blockedUsers() {
            blocked = Set(list.map(\.id))
        }
    }

    /// Who's in it, from its space. Yours alone, it's you and everything in
    /// it.
    private func loadRoster() async {
        guard !current.isLibraryAlbum else { return }
        guard current.isSharedWithPeople, let spaceID = current.spaceID else {
            roster = session.user.map {
                [SpaceMemberDTO(
                    user: $0, role: .owner, joinedAt: current.createdAt,
                    contributedCount: current.itemCount
                )]
            } ?? []
            return
        }
        guard let client = session.client else { return }
        do {
            roster = try await client.members(spaceID: spaceID).members
            rosterFailed = false
        } catch {
            if roster == nil { rosterFailed = true }
        }
    }

    private func setPeople(_ ids: [UUID]) {
        isSaving = true
        Task {
            defer { isSaving = false }
            if await store.setPeople(current, to: ids) {
                failure = nil
                await loadRoster()
            } else {
                failure = store.lastError ?? "That didn't save. Try again."
            }
        }
    }

    /// Takes someone out. The last one out makes the album yours alone, and
    /// it then opens as your own album rather than a shared one — so this
    /// closes first rather than being closed by that change from under it.
    private func remove(_ member: SpaceMemberDTO) {
        let rest = people.map(\.id).filter { $0 != member.user.id }
        guard rest.isEmpty else {
            setPeople(rest)
            return
        }
        let album = current
        onDone()
        Task { await store.setPeople(album, to: []) }
    }

    private func setBlocked(_ isBlocked: Bool, _ userID: UUID) async {
        guard let client = session.client else { return }
        do {
            if isBlocked {
                try await client.block(userID: userID)
                blocked?.insert(userID)
            } else {
                try await client.unblock(userID: userID)
                blocked?.remove(userID)
            }
            session.hiddenContentChanged()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Whether the name took. A blank one puts the old one back.
    private func rename() async -> Bool {
        guard nameChanged else {
            name = current.name
            return true
        }
        if await store.rename(current, to: trimmed) { return true }
        failure = store.lastError ?? "That didn't save. Try again."
        name = current.name
        return false
    }

    /// Done keeps a name typed and not yet submitted, rather than dropping it.
    private func finish() {
        guard current.mayManage, nameChanged else {
            onDone()
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await rename() { onDone() }
        }
    }

    private func resolve(_ report: ContentReportDTO, removing: Bool) {
        guard let client = session.client, let spaceID = current.spaceID else { return }
        Task {
            do {
                if removing {
                    try await client.removeAsset(spaceID: spaceID, assetID: report.assetID)
                }
                try await client.resolveReports(
                    spaceID: spaceID, placementID: report.id,
                    outcome: removing ? .removed : .kept
                )
                reports.removeAll { $0.id == report.id }
                if removing { await store.refresh() }
            } catch {
                failure = error.localizedDescription
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
        .macSheetSize()
        .task {
            if model == nil, let client = session.client {
                model = SpacesModel(client: client)
            }
        }
    }
}

extension View {
    /// The size of a list sheet on a Mac: a library's or an album's Edit, and
    /// Add to Album. A sheet there is as big as what's in it, and a list
    /// inside a stack asks for none at all — Add to Album opened as its title
    /// and Cancel with every album and New Album squeezed out between them.
    /// Nothing elsewhere: a phone's sheet is the screen's.
    func macSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 600)
        #else
        self
        #endif
    }
}
