#if os(macOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Everywhere you can be, all at once, down the left.
///
/// The Mac used to run the same `TabView` as the phone — Photos, Albums,
/// Shared, More — which is a phone's tab bar rendered as a pill in a window
/// title. Four slots is all a phone has room for, so everything else hid behind
/// them: choosing a shared space meant picking the Shared tab and *then*
/// picking a space, and a media type meant Albums, then scrolling, then a list.
///
/// A sidebar has no such budget. Every shared space is a row, every media type
/// is a row, and the thing you want is one click from wherever you are — which
/// is the arrangement Photos, Mail and Music all use, for the same reason.
///
/// Settings left with the tab bar. A Mac keeps preferences behind ⌘, in a panel
/// of their own, not as a fifth destination competing with your library.
struct MacRootView: View {
    @Bindable var session: AppSession

    /// Opens the ⌘, panel from inside the window. Without this the only route
    /// to Settings is the menu bar, which is where a Mac keeps preferences but
    /// is *not* where anyone looks for "sign me out".
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: MacDestination? = .library
    /// The personal library's media types, for the pinned rows.
    ///
    /// Loaded here rather than read from `AlbumsView` because the sidebar
    /// outlives whatever is in the detail pane — these rows have to be there
    /// before you have visited anything.
    ///
    /// Starts from the last list this Mac saw, so the rows are there with the
    /// rest of the sidebar as the window opens. They used to wait for the NAS
    /// to build the whole Albums page — every trip and occasion — and arrived
    /// seconds after Library, Albums and the shared libraries.
    @State private var mediaTypes: [CollectionSummary]

    init(session: AppSession) {
        self.session = session
        _mediaTypes = State(initialValue: session.personalSpace.map(Self.savedMediaTypes) ?? [])
    }

    /// The last media types seen for a library, from their own small file, or
    /// once — on the first launch after this shipped — from the saved Albums
    /// page that already holds them.
    private static func savedMediaTypes(for space: SpaceDTO) -> [CollectionSummary] {
        if let types = AlbumsSnapshotStore.loadMediaTypes(spaceID: space.id) { return types }
        return AlbumsSnapshotStore.loadCollections(spaceID: space.id)?.mediaTypes ?? []
    }
    /// The toolbar's search field. Owned here because the field is part of the
    /// window rather than of whatever the detail pane happens to be showing.
    @State private var query = ""

    /// The Albums page's list, for the albums down the side. The same
    /// store the page draws from, so the two always list the same things.
    private var albums: AlbumStore { session.albumStore() }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // A stack per destination, so pushing into a photo from the Videos
            // row and then switching to Library does not leave you looking at
            // a detail view that belongs to somewhere you have left.
            NavigationStack {
                detail
                    // On the stack's *root*, not on the split view.
                    //
                    // Applied outside, the field stayed in the toolbar after
                    // you opened a photograph — so a viewer showing one image
                    // carried a "Search Places" box wedged against its rotate
                    // and favorite buttons. Searching a library you are not
                    // looking at is not a thing anyone wants, and it crowded
                    // the controls that were.
                    .searchable(
                        text: $query, placement: .toolbar, prompt: "Search Places"
                    )
            }
        }
        // The Albums page, fetched as the window opens rather than when the
        // page is, which also brings the media types in. See `loadMediaTypes`.
        .task(id: session.personalSpace?.id) { await loadMediaTypes() }
        // A shared album made on the phone — or on this Mac's Albums page —
        // has to reach the sidebar without the Albums page being opened first.
        .task { await albums.refreshIfStale() }
        // And again on coming back to the window, the moment the grids look
        // again too: one shared with you on the phone in the meantime turns
        // up without a visit to Albums first, and today's page comes in
        // before you open it. The page holds what it has while it's showing
        // (`CollectionsStore.take`).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await albums.refreshIfStale() }
            if let personal = session.personalSpace {
                Task { await session.collectionsStore(for: personal.id).refreshIfStale() }
            }
        }
        // A notification or the activity list pointing at a shared library
        // or album: select it, the way clicking its row would. The phone opens
        // the same thing from its Albums tab.
        .onChange(of: session.pendingLibrary, initial: true) { _, pending in
            guard let pending else { return }
            session.pendingLibrary = nil
            if pending.reviewingReports { session.pendingReportReview = pending.spaceID }
            if session.spaces.contains(where: { $0.id == pending.spaceID }) {
                selection = .space(pending.spaceID)
            } else if let album = albums.sharedWithPeople
                .first(where: { $0.spaceID == pending.spaceID }) {
                selection = .album(album.id)
            }
        }
        // Gone from under you — left, deleted, or someone else took you out:
        // back to Albums rather than an "unavailable" page for something
        // that's no longer anywhere in the sidebar.
        .onChange(of: selectionIsGone) { _, gone in
            if gone { selection = .albums }
        }
    }

    /// Whether the shared library or album the sidebar points at has gone.
    private var selectionIsGone: Bool {
        switch selection {
        case .space(let id):
            return !session.spaces.isEmpty && !session.spaces.contains { $0.id == id }
        case .album(let id):
            return albums.hasLoaded && !albums.albums.contains { $0.id == id }
        default:
            return false
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Library", systemImage: "photo.on.rectangle.angled")
                    .tag(MacDestination.library)
                Label("Albums", systemImage: "rectangle.stack")
                    .tag(MacDestination.albums)
            }

            // Your own albums, the Albums page's "Albums" row for row, above
            // the shared ones as on the page. The sidebar listed every shared
            // album by name and none of yours, so an album only you can see
            // was the one thing here two clicks away. "My Albums", as Photos
            // heads them, because the row above is already called Albums.
            let mine = albums.personal
            if !mine.isEmpty {
                Section("My Albums") {
                    ForEach(mine) { album in
                        Label(album.name, systemImage: "rectangle.stack")
                            .tag(MacDestination.album(album.id))
                    }
                }
            }

            // Everything shared, by name — the Albums page's Shared Albums,
            // row for row and in its order: albums shared with people, then
            // each shared library and the albums made in it. It listed only
            // the libraries, so an album shared with the family was on the
            // Albums page and nowhere down here.
            let shared = albums.sharedEntries(libraries: session.sharedSpaces)
            if !shared.isEmpty {
                Section("Shared Albums") {
                    ForEach(shared) { entry in
                        switch entry {
                        case .library(let space):
                            Label(space.name, systemImage: "person.2")
                                .tag(MacDestination.space(space.id))
                        case .album(let album):
                            // The same two people as a library's row, as on
                            // the cards: under this heading they're all
                            // shared albums, and a different mark made one
                            // look like a different kind of thing.
                            Label(album.name, systemImage: "person.2")
                                .tag(MacDestination.album(album.id))
                        }
                    }
                }
            }

            // Only the types this library actually has — the server omits a
            // type with nothing in it, so somebody with no slo-mo never grows
            // a Slo-mo row.
            if !mediaTypes.isEmpty {
                Section("Media Types") {
                    ForEach(mediaTypes, id: \.key) { type in
                        Label(type.title, systemImage: Self.icon(for: type.key))
                            .tag(MacDestination.mediaType(type.key))
                    }
                }
            }

            Section("Utilities") {
                Label("Recently Deleted", systemImage: "trash")
                    .tag(MacDestination.recentlyDeleted)
                Label("Manage Shared Libraries", systemImage: "person.2.badge.gearshape")
                    .tag(MacDestination.spaces)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        .safeAreaInset(edge: .bottom) { account }
    }

    /// Who you are, where you're connected, and what you can do about it.
    ///
    /// The old More tab opened onto this; with settings behind ⌘, there was
    /// nowhere left to say which NAS you are looking at — which matters most to
    /// exactly the person who has more than one.
    ///
    /// It is a menu rather than a label because the first thing that happened
    /// when settings moved to ⌘, was that Sign Out became unreachable. A Mac
    /// genuinely does keep preferences in the menu bar, but nobody hunts the
    /// menu bar to sign out — they look at their own name, which is here. So
    /// the row states both and offers both, and ⌘, still works for anyone who
    /// reaches for it.
    private var account: some View {
        Menu {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Sign Out", role: .destructive) { session.signOut() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let host = session.serverHost {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        // Typing shows results over whatever was selected, and clearing the
        // field puts you back exactly where you were — the sidebar selection is
        // never disturbed, so search is a lens rather than a detour.
        //
        // It searches the library on screen: a shared library or shared album
        // searches itself, everything else your own library — the phone's
        // rule. It used to search your own library from inside Family Shared.
        if !query.isEmpty, let space = searchSpace ?? session.personalSpace {
            SearchView(session: session, space: space, query: $query)
                // A different library is a different search, not the last
                // one's results under a new name.
                .id(space.id)
        } else {
            destination
        }
    }

    /// The shared library or album the sidebar is on, for search.
    private var searchSpace: SpaceDTO? {
        switch selection {
        case .space(let id): SharedAlbumRoute(spaceID: id).target(in: session).searchSpace
        case .album(let id): albumRoute(id)?.target(in: session).searchSpace
        default: nil
        }
    }

    /// An album's route, from what the device knows of it now.
    private func albumRoute(_ id: UUID) -> SharedAlbumRoute? {
        guard let album = albums.albums.first(where: { $0.id == id }) else { return nil }
        return SharedAlbumRoute(spaceID: album.spaceID ?? album.id, albumID: id)
    }

    @ViewBuilder
    private var destination: some View {
        switch selection ?? .library {
        case .library:
            if let personal = session.personalSpace {
                TimelineView(session: session, space: personal)
            } else {
                ProgressView()
            }

        case .albums:
            AlbumsView(session: session)
                // A shared library's or shared album's card opens it here,
                // with a way back to Albums, as it does on the phone — the
                // same screen its sidebar row shows, search field and all.
                // The field is the pushed screen's own: the window's belongs
                // to the page underneath, and leaving this screen should come
                // back to the page as it was.
                .navigationDestination(for: SharedAlbumRoute.self) { route in
                    MacSearchLens(session: session, space: route.target(in: session).searchSpace) {
                        shared(route, isPushed: true)
                    }
                }

        case .space(let id):
            shared(SharedAlbumRoute(spaceID: id), isPushed: false)

        case .album(let id):
            if let route = albumRoute(id) {
                shared(route, isPushed: false)
            } else {
                unavailable
            }

        case .mediaType(let key):
            if let personal = session.personalSpace,
               let type = mediaTypes.first(where: { $0.key == key }) {
                CollectionDetailView(session: session, space: personal, collection: type)
            } else {
                ProgressView()
            }

        case .recentlyDeleted:
            if let personal = session.personalSpace {
                RecentlyDeletedView(session: session, space: personal)
            } else {
                ProgressView()
            }

        case .spaces:
            SpacesView(session: session)
        }
    }

    /// A shared library or album, the same screen from its sidebar row and
    /// from its card on the Albums page. See `SharedAlbumTarget`.
    @ViewBuilder
    private func shared(_ route: SharedAlbumRoute, isPushed: Bool) -> some View {
        switch route.target(in: session) {
        case .library(let space):
            TimelineView(session: session, space: space, isPushed: isPushed)
        case .peopleAlbum(let album, let space):
            TimelineView(session: session, space: space, isPushed: isPushed, albumID: album.id)
        case .album(let album):
            AlbumDetailView(session: session, album: album, store: albums)
                // A screen per album. Without it, clicking from one of My
                // Albums to the next kept the same screen — same place in this
                // switch — and it went on showing the first album, which it
                // holds in its own state and loads once. A pushed album is a
                // new screen each time, so only the sidebar met this.
                .id(album.id)
        case .unavailable:
            unavailable
        }
    }

    /// Removed while it was on screen.
    private var unavailable: some View {
        ContentUnavailableView {
            Label("Album Unavailable", systemImage: "person.2.slash")
        } description: {
            Text("This isn't shared with you anymore.")
        }
    }

    // MARK: - Loading

    /// From the Albums page's own request, which carries them. This asked the
    /// NAS for the whole page itself, and now that the page is fetched as the
    /// window opens too, that was the same heavy request twice.
    private func loadMediaTypes() async {
        guard let personal = session.personalSpace else { return }
        // Signed in, or the spaces arrived, after the window opened.
        if mediaTypes.isEmpty { mediaTypes = Self.savedMediaTypes(for: personal) }
        let store = session.collectionsStore(for: personal.id)
        await store.refreshIfStale()
        // Only an answer. A failed refresh that assigned nil would empty the
        // sidebar over a library that is perfectly fine — the same mistake the
        // Albums page made once already — and the store's page before one is
        // the saved copy, no newer than what's here.
        guard store.hasAnswered, let types = store.page?.mediaTypes else { return }
        // Assigned only when different, so an unchanged answer doesn't
        // rebuild the sidebar under someone's pointer.
        if types != mediaTypes { mediaTypes = types }
        let spaceID = personal.id
        Task.detached(priority: .utility) {
            AlbumsSnapshotStore.saveMediaTypes(types, spaceID: spaceID)
        }
    }

    /// The rows read as a list of *kinds*, so each needs a mark of its own —
    /// six identical rectangles would be a list you have to read every time.
    static func icon(for key: String) -> String {
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

/// Where the sidebar can point.
///
/// One enum rather than a bag of booleans: the detail pane switches on exactly
/// one value, so there is no arrangement of state that shows two things or none.
enum MacDestination: Hashable {
    case library
    case albums
    /// A shared library.
    case space(UUID)
    /// An album, yours or shared, by its own id.
    case album(UUID)
    case mediaType(String)
    case recentlyDeleted
    case spaces
}

/// A search field for a screen pushed inside the detail pane, searching the
/// library that screen shows.
///
/// The window's own field is on the stack's root and leaves with it, so a
/// shared library opened from its card on the Albums page had no field, while
/// the same library from its sidebar row did. This gives the pushed screen
/// the same field, with its own text: typing here and going back leaves the
/// Albums page as it was.
struct MacSearchLens<Content: View>: View {
    @Bindable var session: AppSession
    /// What to search. Nil: the personal library.
    let space: SpaceDTO?
    @ViewBuilder let content: () -> Content

    @State private var query = ""

    var body: some View {
        Group {
            if !query.isEmpty, let space = space ?? session.personalSpace {
                SearchView(session: session, space: space, query: $query)
                    .id(space.id)
            } else {
                content()
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Places")
    }
}

#endif
