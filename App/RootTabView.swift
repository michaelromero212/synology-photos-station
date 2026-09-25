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
    @Environment(\.scenePhase) private var scenePhase
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

    #if os(iOS)
    /// The library the search sheet is searching, and whether it is up at all.
    /// Search is the circle beside the bar rather than a tab in it — see
    /// `FloatingTabBar`.
    ///
    /// The sheet's item rather than a flag beside a value. A value read only
    /// inside `sheet(isPresented:)` is captured from before it was set, so the
    /// first search from a shared album searched the personal library.
    @State private var searchSpace: SpaceDTO?
    /// Backup setup, offered after sign-in the way a fresh install offers it.
    /// See `BackupAccount`.
    @State private var showBackupSetup = false
    #endif

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
        #if os(iOS)
        // Ours takes the system bar's place — the system's own is hidden per
        // tab, in `tabContainer`. See `FloatingTabBar` for why it is drawn by
        // hand rather than declared.
        //
        // An overlay rather than an inset, so nothing about the bar's own
        // presence resizes a scroll view: photographs pass under the glass as
        // you scroll, which is the whole point of it floating. What stops them
        // coming to *rest* under it is a constant margin on each screen — see
        // `floatingTabBarClearance`.
        .overlay(alignment: .bottom) {
            // Gone while a grid is selecting or a photo is open, because each
            // puts its own bar in exactly this place and two of them there is
            // one too many. See `GridChrome`.
            ZStack {
                if !GridChrome.shared.hidesTabBar {
                    FloatingTabBar(
                        items: [
                            .init(tab: Tabs.photos, title: "Photos", symbol: "photo.on.rectangle"),
                            .init(tab: Tabs.albums, title: "Albums", symbol: "rectangle.stack"),
                            .init(tab: Tabs.more, title: "More", symbol: "ellipsis"),
                        ],
                        selection: $tab,
                        onSearch: { searchSpace = spaceOnScreen }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // The bar's animation, on the bar alone. An overlay, so neither its
            // arrival nor its departure resizes a scroll view.
            //
            // This sat on the whole tab container, and an `.animation(_:value:)`
            // animates *everything* beneath it that changes in the same moment
            // as its value — the lesson `RootView` records about the sign-in
            // fade. A photo opening hides the bar in the very frame its zoom
            // out of the grid begins, so the zoom was taken over by this
            // quarter-second ease: SwiftUI counted the zoom's own spring as
            // finished before it had started, and the viewer cut in over a
            // photo still near its tile.
            .animation(.easeInOut(duration: 0.22), value: GridChrome.shared.hidesTabBar)
        }
        .sheet(item: $searchSpace) { space in
            NavigationStack {
                search(in: space)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { searchSpace = nil }
                        }
                    }
            }
        }
        // The same screen as More → Photo Backup → Settings, not a lighter
        // version of it: everything a first backup needs to decide — photo
        // access, on or off, all photos or only new ones, Wi-Fi and power — is
        // already there, and a second copy would drift from the first.
        // Dismissing it by any route counts as having been offered; backup stays
        // off unless it was switched on.
        .sheet(isPresented: $showBackupSetup, onDismiss: { BackupAccount.setupOffered = true }) {
            if let engine {
                BackupSettingsView(
                    session: session, engine: engine, settings: $backupSettings
                ) { showBackupSetup = false }
            }
        }
        .environment(\.connectionMonitor, connection)
        // Leaving the app is when the NAS most needs the truth about this
        // device's backlog, and the one moment a run cannot report it itself: a
        // run that is interrupted by being backgrounded never reaches its own
        // end. Without this, somebody who adds five hundred photographs and then
        // switches apps leaves the server believing there is nothing to wake
        // them for. See `BackupEngine.reportBackupState`.
        //
        // And coming back is when a backup left unfinished should carry on.
        // See `BackupEngine.resume`.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                engine?.reportBackupState(force: true)
            case .active:
                Task { await engine?.resume() }
            default:
                break
            }
        }
        .task { [session] in
            guard engine == nil, let container = modelContainer else { return }
            // Before anything reads the ledger: it may belong to whoever was
            // signed in last. See `BackupAccount.adopt`.
            if let userID = session.user?.id {
                BackupAccount.adopt(userID: userID, container: container)
            }
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
            // Signing out has to stop this engine, and the session is what
            // knows about the sign-out. See `BackupEngine.retire`.
            session.willSignOut = { [weak created] in created?.retire() }
            // Offered once per sign-in, the way a fresh install offers it —
            // and not to someone who already has backup running.
            //
            // After the notification question, never on top of it. On a first
            // launch both arrive together, and the alert landed over the sheet.
            // Its own task so waiting for that answer holds up nothing below.
            if !BackupAccount.setupOffered, !backupSettings.enabled {
                Task {
                    await PushRegistrar.shared.askOnce()
                    showBackupSetup = true
                }
            }
            // Before the first grid draws, and whether or not backup is on:
            // this is what lets a tile whose thumbnail the NAS has not made yet
            // be drawn from the copy still on the phone. See `LocalOriginals`.
            created.seedLocalOriginals()
            if backupSettings.enabled { created.enableBackgroundRuns() }
            // The launch's own `.active` can arrive before this engine exists,
            // so the first pick-up is asked for here as well. Not waited for:
            // it runs for as long as the queue does.
            Task { await created.resume() }
            // Finish anything a share left outstanding when the app was last
            // taken away. Automatic backup has always resumed itself; this is
            // the manual path getting the same treatment — see `ManualUpload`.
            if let client = session.client {
                await session.pendingUploads.attach(container: container, client: client)
            }
        }
        #endif
    }

    /// The screens, and who draws the bar over them.
    ///
    /// On iOS the system's own bar is hidden and `FloatingTabBar` takes its
    /// place — the reasoning is there, not here. This still uses `TabView`
    /// because it is what switches the screens and keeps each one's navigation
    /// stack alive; only the chrome is ours.
    ///
    /// A television keeps the system bar and the fourth tab. There is no corner
    /// to float a button in, and the focus engine should own the bar rather
    /// than compete with something hand-drawn.
    @ViewBuilder
    private var tabContainer: some View {
        if #available(iOS 18.0, tvOS 18.0, *) {
            TabView(selection: $tab) {
                Tab("Photos", systemImage: "photo.on.rectangle", value: Tabs.photos) {
                    systemBarHidden { NavigationStack { photosTab } }
                }
                Tab("Albums", systemImage: "rectangle.stack", value: Tabs.albums) {
                    systemBarHidden { albumsTab }
                }
                Tab("More", systemImage: "ellipsis", value: Tabs.more) {
                    systemBarHidden { NavigationStack { moreTab } }
                }
                #if os(tvOS)
                // A television keeps the system's fourth tab: there is no
                // corner to put a floating button in, and the focus engine
                // should own the bar.
                Tab("Search", systemImage: "magnifyingglass", value: Tabs.search) {
                    NavigationStack { search(in: nil) }
                }
                #endif
            }
        } else {
            TabView(selection: $tab) {
                systemBarHidden { NavigationStack { photosTab } }
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(Tabs.photos)

                systemBarHidden { albumsTab }
                    .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                    .tag(Tabs.albums)

                systemBarHidden { NavigationStack { moreTab } }
                    .tabItem { Label("More", systemImage: "ellipsis") }
                    .tag(Tabs.more)

                #if os(tvOS)
                NavigationStack { search(in: nil) }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tabs.search)
                #endif
            }
        }
    }

    /// Takes the system's bar out from under ours.
    ///
    /// Set on a tab's *content* and not on the `TabView`, which is where it was
    /// first and where it did nothing: tab-bar visibility travels upwards from
    /// the content of a tab to the bar that owns it, so a modifier sitting
    /// outside the container is above the thing meant to read it. A screenshot
    /// is what caught it — the system's bar drawn centered behind ours, the same
    /// three labels twice, a few points apart.
    ///
    /// Hiding it also takes away the room it reserved, which every screen under
    /// our bar now has to ask for itself — `floatingTabBarClearance`. It cannot
    /// be done here for the same reason the hiding *has* to be: what a tab sets
    /// does not reach the screens a navigation stack shows inside it.
    ///
    /// A television keeps its bar, so this is nothing there.
    @ViewBuilder
    private func systemBarHidden(
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        #if os(iOS)
        content().toolbar(.hidden, for: .tabBar)
        #else
        content()
        #endif
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

    /// Search, scoped to one library — the personal one unless told otherwise.
    ///
    /// Searching every library at once is a server question rather than a
    /// navigation one — `/search` is per-space — so the button searches the
    /// library you are looking at. See `spaceOnScreen`.
    @ViewBuilder
    private func search(in space: SpaceDTO?) -> some View {
        if let space = space ?? session.personalSpace {
            SearchView(session: session, space: space)
        } else {
            ProgressView()
        }
    }

    #if os(iOS)
    /// The library on screen, which is the one the search button searches.
    ///
    /// A shared album open in the Albums tab searches itself; everywhere else —
    /// the Photos tab, the Albums page, More — is the personal library. Shared
    /// albums used to carry a magnifier of their own in their top bar, because
    /// this button only ever searched the personal library; one button in one
    /// place, searching whatever you are looking at, is simpler, and it is where
    /// Photos keeps it.
    private var spaceOnScreen: SpaceDTO? {
        if tab == .albums, let route = albumsPath.last,
           let shared = session.spaces.first(where: { $0.id == route.spaceID }) {
            return shared
        }
        return session.personalSpace
    }
    #endif

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
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
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
                // Pushed, so it needs the bar's room; the same screen opened as
                // a sheet from the grid does not — hence the flag rather than a
                // modifier on the screen itself.
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
