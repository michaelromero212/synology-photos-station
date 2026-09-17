import FrameStationAPI
import FrameStationKit
// `backupContainer` is a `ModelContainer`, declared as a property below.
import SwiftData
import SwiftUI

/// The app's three places — your photos, your albums, everything else — and a
/// search button in the corner.
///
/// Shaped after Photos, deliberately and in detail, because this app is meant
/// to read as a continuation of it rather than as a rival to it. Someone who
/// knows where things are in Photos should not have to learn where they are
/// here.
///
/// Shared albums had a tab of their own and no longer do. It was empty for
/// anyone who shares nothing, and for everyone else it was a second place to
/// look for a named set of photographs — which is what an album is. They sit on
/// the Albums page now, below the ones you made yourself.
struct RootTabView: View {
    @Bindable var session: AppSession

    #if os(iOS)
    /// One engine for the whole app.
    ///
    /// Built here rather than per-tab: two instances over the same queue would
    /// each claim work and each schedule background runs, so a photo could be
    /// uploaded twice and the tabs would disagree about progress.
    @Environment(\.backupContainer) private var modelContainer
    @State private var engine: BackupEngine?
    @State private var backupSettings = BackupSettings.load()
    /// Built alongside the engine and shared with it: the engine is what
    /// discovers an outage, and the grid is what has to say so.
    @State private var connection: ConnectionMonitor?
    /// What just landed in a shared album, for checking.
    ///
    /// Held here because sharing happens in the grid you are *leaving* — usually
    /// the Photos tab — and the review belongs to the grid you arrive at. A tab
    /// cannot hand state to a screen inside another tab; their parent can.
    @State private var review: MoveReview?
    #endif

    /// Which tab is on screen. Bound so following a share can move you.
    @State private var tab = Tabs.photos

    /// What the Albums tab has pushed on top of itself.
    ///
    /// Owned here rather than inside `AlbumsView` for the same reason the
    /// review is: a share that starts in the Photos tab has to be able to open
    /// the shared album it landed in, and that album is now a screen *inside*
    /// another tab rather than a tab of its own. Only the parent can both
    /// switch tabs and push.
    @State private var albumsPath: [SharedAlbumRoute] = []

    private enum Tabs: Hashable { case photos, albums, more, search }

    var body: some View {
        #if os(macOS)
        // A Mac gets a sidebar, not a tab bar — see MacSidebar.swift.
        MacRootView(session: session)
        #else
        tabs
        #endif
    }

    #if !os(macOS)
    private var tabs: some View {
        tabContainer
        // On the TabView rather than per-tab: the bar is one control shared by
        // all of them, and setting it four times is four chances to miss one.
        .glassTabBar()
        #if os(iOS)
        .environment(\.connectionMonitor, connection)
        .task { [session] in
            guard engine == nil, let container = modelContainer else { return }
            // `session` is captured explicitly above so this weak capture reads
            // as what it is: the monitor outlives this task and must not
            // retain the session, even though the task itself holds it.
            let monitor = ConnectionMonitor { [weak session] in session?.client }
            monitor.start()
            let created = BackupEngine(
                container: container, session: session, settings: backupSettings,
                connection: monitor
            )
            // Picking up where the outage stopped it. Waiting for the next
            // background window instead would mean a phone that reconnects on
            // the sofa does nothing until iOS decides to wake us.
            monitor.onReconnect = { [weak created] in await created?.start() }
            connection = monitor
            engine = created
            // Before the first grid draws, and whether or not backup is on:
            // this is what lets a tile whose thumbnail the NAS has not made yet
            // be drawn from the copy still on the phone. See `LocalOriginals`.
            created.seedLocalOriginals()
            if backupSettings.enabled { created.enableBackgroundRuns() }
        }
        #endif
    }

    /// Three places and a search button.
    ///
    /// Two shapes of the same four screens. The `Tab` builder is iOS 18, and
    /// it is worth branching for exactly one reason: a tab declared with
    /// `role: .search` is drawn by the system as a detached circle at the
    /// trailing end of the bar, which is where Photos puts search and what was
    /// asked for. Hand-rolling that as a floating button would mean guessing
    /// the bar's height, its inset and its glass, and guessing again every
    /// time the system changed them.
    ///
    /// On 17 the same four tabs render as four ordinary items. Search is then
    /// simply the last one rather than a separate control — a plainer bar, not
    /// a broken one.
    @ViewBuilder
    private var tabContainer: some View {
        if #available(iOS 18.0, tvOS 18.0, *) {
            TabView(selection: $tab) {
                Tab("Photos", systemImage: "photo.on.rectangle", value: Tabs.photos) {
                    NavigationStack { photosTab }
                }
                Tab("Albums", systemImage: "rectangle.stack", value: Tabs.albums) {
                    albumsTab
                }
                Tab("More", systemImage: "ellipsis", value: Tabs.more) {
                    NavigationStack { moreTab }
                }
                Tab(
                    "Search", systemImage: "magnifyingglass",
                    value: Tabs.search, role: .search
                ) {
                    NavigationStack { searchTab }
                }
            }
        } else {
            TabView(selection: $tab) {
                NavigationStack { photosTab }
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(Tabs.photos)

                albumsTab
                    .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                    .tag(Tabs.albums)

                NavigationStack { moreTab }
                    .tabItem { Label("More", systemImage: "ellipsis") }
                    .tag(Tabs.more)

                NavigationStack { searchTab }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tabs.search)
            }
        }
    }

    @ViewBuilder
    private var photosTab: some View {
        if let personal = session.personalSpace {
            photosTimeline(personal)
        } else {
            ProgressView()
        }
    }

    /// Albums, with the shared ones on the same page.
    ///
    /// The stack lives out here holding a path, because a share that finishes
    /// in the Photos tab has to be able to open the shared album it landed in —
    /// see `followShare`.
    private var albumsTab: some View {
        NavigationStack(path: $albumsPath) {
            AlbumsView(session: session)
                .navigationDestination(for: SharedAlbumRoute.self) { route in
                    sharedAlbum(route.spaceID)
                }
        }
    }

    /// Search, scoped to the personal library.
    ///
    /// The same screen the magnifier in the grid's top bar used to open, which
    /// is why it takes a space at all. Searching every library at once is a
    /// server question rather than a navigation one — `/search` is per-space —
    /// so this searches the one people mean when they say "my photos", and
    /// finding something inside a shared album still means opening it.
    @ViewBuilder
    private var searchTab: some View {
        if let personal = session.personalSpace {
            SearchView(session: session, space: personal)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var moreTab: some View {
        #if os(iOS)
        MoreView(session: session, engine: engine, settings: $backupSettings)
        #else
        MoreView(session: session)
        #endif
    }

    /// One shared album, opened from the Albums page.
    ///
    /// Resolved from the session rather than carried in the route, so renaming
    /// it from inside updates the title you are looking at.
    @ViewBuilder
    private func sharedAlbum(_ spaceID: UUID) -> some View {
        if let space = session.spaces.first(where: { $0.id == spaceID }) {
            #if os(iOS)
            TimelineView(
                session: session, space: space,
                engine: engine, backupSettings: $backupSettings,
                isPushed: true,
                onShared: followShare,
                review: review,
                onReviewDone: { review = nil },
                onRemoveOriginals: removeOriginals
            )
            #else
            TimelineView(session: session, space: space, isPushed: true)
            #endif
        } else {
            // Left rather than left behind: someone else can remove you from a
            // shared album while you are looking at the list it was on.
            ContentUnavailableView {
                Label("Album unavailable", systemImage: "person.2.slash")
            } description: {
                Text("This shared album isn't available to you any more.")
            }
        }
    }

    @ViewBuilder
    private func photosTimeline(_ space: SpaceDTO) -> some View {
        #if os(iOS)
        TimelineView(
            session: session, space: space,
            engine: engine, backupSettings: $backupSettings,
            onShared: followShare
        )
        #else
        TimelineView(session: session, space: space)
        #endif
    }

    #if os(iOS)
    /// Goes where the photos went.
    ///
    /// The same three steps wherever the share started: remember what landed and
    /// where it came from, open the shared album it landed in, then show the tab
    /// that album lives on. Ordered so the grid is already looking at the right
    /// album by the time it appears — switching tabs first would flash the
    /// previous one.
    ///
    /// The destination used to be a tab; it is a screen inside Albums now, so
    /// "point at it" means setting the path rather than an id. Assigning the
    /// whole path rather than appending matters: following two shares in a row
    /// should land you in the second album, not stack one on the other with a
    /// back chevron into a review you have already finished.
    private func followShare(
        destination: SpaceDTO, result: ShareAssetsResponse, from: SpaceDTO
    ) {
        review = MoveReview(
            assetIDs: result.assetIDs,
            destinationName: destination.name,
            source: MoveReview.Source(space: from, assetIDs: result.sourceAssetIDs)
        )
        albumsPath = [SharedAlbumRoute(spaceID: destination.id)]
        tab = .albums
    }

    /// Clears the originals from the album they were shared out of.
    ///
    /// Offered rather than assumed, and offered *after* the copies are visibly
    /// sitting in the destination — that is the only point at which agreeing to
    /// it is an informed decision rather than a guess about whether the share
    /// worked.
    ///
    /// Failures are collected rather than fatal: nineteen of twenty removed is
    /// a better outcome than nothing removed, and the one that didn't is still
    /// in the library where it started.
    private func removeOriginals() {
        guard let review, let source = review.source, let client = session.client else { return }
        review.isRemoving = true
        review.removeError = nil
        Task {
            var failed = 0
            for assetID in source.assetIDs {
                do {
                    try await client.removeAsset(spaceID: source.space.id, assetID: assetID)
                } catch {
                    failed += 1
                }
            }
            review.isRemoving = false
            if failed == 0 {
                review.removedOriginals = true
            } else {
                review.removeError = failed == source.assetIDs.count
                    ? "Couldn't remove the originals."
                    : "\(failed) of \(source.assetIDs.count) couldn't be removed."
                review.removedOriginals = failed < source.assetIDs.count
            }
        }
    }
    #endif
    #endif
}


/// Settings and everything that isn't a photo.
struct MoreView: View {
    @Bindable var session: AppSession
    #if os(iOS)
    let engine: BackupEngine?
    @Binding var settings: BackupSettings
    @State private var showBackup = false
    #endif

    var body: some View {
        container
        .navigationTitle("More")
        #if os(iOS)
        .sheet(isPresented: $showBackup) {
            if let engine {
                BackupHubView(
                    session: session, engine: engine, settings: $settings
                ) { showBackup = false }
            } else {
                // Never present an empty sheet: if the queue hasn't opened yet,
                // say so rather than showing a blank card.
                ProgressView("Opening backup…")
            }
        }
        #endif
    }

    /// Kept as a `List` — this view is the phone's and the TV's now.
    ///
    /// It briefly grew a grouped-`Form` branch for the Mac, when the Mac still
    /// had a More tab to put it in. macOS settings moved behind ⌘, in
    /// `MacSettingsView`, so that branch became a macOS layout nothing on macOS
    /// could reach.
    @ViewBuilder
    private var container: some View {
        List { sections }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(.headline)
                    if let host = session.serverHost {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        Section {
            #if os(iOS)
            Button {
                showBackup = true
            } label: {
                Label(backupStatus, systemImage: backupIcon)
            }
            .tint(.primary)
            #endif
            NavigationLink {
                SpacesView(session: session)
            } label: {
                Label("Manage Shared Albums", systemImage: "person.2.badge.gearshape")
            }
        }

        Section {
            AutoPlayToggle()
            VideoQualityPicker()
            // iOS only: the point of exporting is to read a log from a
            // phone that was on cellular, where the console cannot reach.
            // A Mac can just be looked at.
            #if os(iOS)
            DiagnosticsExportButton()
            #endif
        } header: {
            Text("Playback")
        } footer: {
            Text(
                "When a video ends, continue to the next video from the "
                + "same day. Turn this off to play only the video you opened."
            )
        }

        Section("Offline") {
            NavigationLink {
                CacheManagementView(session: session)
            } label: {
                Label("Cache Management", systemImage: "internaldrive")
            }
        }

        Section {
            AppearancePicker()
        } footer: {
            Text("Dark keeps the interface out of the way of your photos.")
        }

        Section {
            Button(role: .destructive) {
                session.signOut()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } footer: {
            Text("FrameStation \(Bundle.appVersion)")
        }
    }

    #if os(iOS)
    /// Mirrors the wording on Synology's own row, because "Photo Backup
    /// Complete" tells you the thing you actually want to know at a glance.
    private var backupStatus: String {
        guard settings.enabled else { return "Photo Backup Off" }
        guard let engine else { return "Photo Backup" }
        if engine.progress.pending > 0 {
            return "Backing Up — \(engine.progress.pending) left"
        }
        return engine.progress.done > 0 ? "Photo Backup Complete" : "Photo Backup"
    }

    private var backupIcon: String {
        guard settings.enabled else { return "icloud.slash" }
        return (engine?.progress.pending ?? 0) > 0
            ? "icloud.and.arrow.up" : "checkmark.icloud"
    }
    #endif
}

extension Bundle {
    static var appVersion: String {
        let version = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}
