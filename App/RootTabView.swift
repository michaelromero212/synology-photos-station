import FrameStationAPI
import FrameStationKit
import SwiftUI

/// The app's four places: your photos, your albums, what the family shares,
/// and everything else.
///
/// Replaces the space dropdown in the title bar. Personal and shared libraries
/// are different enough — one is yours, one is everyone's — that hiding the
/// switch inside a menu made the shared space easy to forget existed.
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
    /// Which shared space the Shared tab is showing, and what just landed there
    /// for checking.
    ///
    /// Held here rather than inside `SharedTab` because sharing happens in the
    /// grid you are *leaving* — usually the Photos tab — and the review belongs
    /// to the grid you arrive at. Two sibling tabs cannot hand state to each
    /// other; their parent can.
    @State private var sharedSpaceID: UUID?
    @State private var review: MoveReview?
    #endif

    /// Which tab is on screen. Bound so following a share can move you.
    @State private var tab = Tabs.photos

    private enum Tabs: Hashable { case photos, albums, shared, more }

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
        // `.tabItem` rather than the iOS 18 `Tab` builder: the deployment
        // target is 17, and this form behaves identically on both.
        TabView(selection: $tab) {
            NavigationStack {
                if let personal = session.personalSpace {
                    photosTimeline(personal)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            .tag(Tabs.photos)

            NavigationStack { AlbumsView(session: session) }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                .tag(Tabs.albums)

            NavigationStack { sharedTab }
                .tabItem { Label("Shared", systemImage: "person.2") }
                .tag(Tabs.shared)

            NavigationStack { moreTab }
            .tabItem { Label("More", systemImage: "ellipsis") }
            .tag(Tabs.more)
        }
        // On the TabView rather than per-tab: the bar is one control shared by
        // all four, and setting it four times is four chances to miss one.
        .glassTabBar()
        #if os(iOS)
        .environment(\.connectionMonitor, connection)
        .task {
            guard engine == nil, let container = modelContainer else { return }
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
            if backupSettings.enabled { created.enableBackgroundRuns() }
        }
        #endif
    }

    @ViewBuilder
    private var moreTab: some View {
        #if os(iOS)
        MoreView(session: session, engine: engine, settings: $backupSettings)
        #else
        MoreView(session: session)
        #endif
    }

    @ViewBuilder
    private var sharedTab: some View {
        #if os(iOS)
        SharedTab(
            session: session, engine: engine, backupSettings: $backupSettings,
            selectedSpaceID: $sharedSpaceID, review: $review,
            onShared: followShare
        )
        #else
        SharedTab(session: session)
        #endif
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
    /// where it came from, point the Shared tab at the destination, then show
    /// that tab. Ordered so the grid is already looking at the right space by
    /// the time it appears — switching tabs first would flash the previous one.
    private func followShare(
        destination: SpaceDTO, result: ShareAssetsResponse, from: SpaceDTO
    ) {
        review = MoveReview(
            assetIDs: result.assetIDs,
            destinationName: destination.name,
            source: MoveReview.Source(space: from, assetIDs: result.sourceAssetIDs)
        )
        sharedSpaceID = destination.id
        tab = .shared
    }

    private var engineIfReady: BackupEngine? { engine }
    #endif
    #endif
}

/// The family's shared spaces, no longer buried in a dropdown.
///
/// One shared space opens straight into it — a list of one is a wasted tap.
/// Several get a list, because at that point the choice is real.
struct SharedTab: View {
    @Bindable var session: AppSession
    #if os(iOS)
    let engine: BackupEngine?
    @Binding var backupSettings: BackupSettings
    #endif

    /// Which shared space is on screen, and what just landed in it.
    ///
    /// Owned by `RootTabView`: a share that starts in the Photos tab has to be
    /// able to point this tab at a destination before it is even on screen, and
    /// state private to this view could not be reached from there.
    #if os(iOS)
    @Binding var selectedSpaceID: UUID?
    @Binding var review: MoveReview?
    let onShared: (SpaceDTO, ShareAssetsResponse, SpaceDTO) -> Void
    #else
    @State private var selectedSpaceID: UUID?
    #endif

    var body: some View {
        Group {
            let shared = session.spaces.filter { $0.kind == .shared }
            if shared.isEmpty {
                ContentUnavailableView {
                    Label("Nothing shared yet", systemImage: "person.2")
                } description: {
                    Text("Create a shared space and everyone in it sees the same photos.")
                } actions: {
                    NavigationLink("Manage Spaces") {
                        SpacesView(session: session) {}
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Always the grid, never a list of names.
                //
                // A list was a whole screen that showed no photographs and
                // existed only to be tapped through — and it appeared the moment
                // a second shared space existed, so the tab changed shape
                // underneath people who had got used to landing straight in
                // their library. Switching spaces is now a title-bar menu, the
                // way choosing a library is everywhere else, and the grid is
                // what you see the instant the tab opens.
                let current = shared.first { $0.id == selectedSpaceID } ?? shared[0]
                timeline(for: current, switcher: switcher(among: shared, current: current))
                    #if os(iOS)
                    // Following a move is the whole point of the review: the
                    // photos went somewhere, so go there. Switching the space
                    // and handing down what arrived are one action.
                    .id(current.id)
                    #endif
            }
        }
        .task { await session.refreshSpaces() }
    }

    /// The title-bar space picker, or nil when there is nothing to pick between.
    ///
    /// One shared space gets a plain title: a menu whose only entry is already
    /// ticked is a control that does nothing, and the chevron promises otherwise.
    private func switcher(among spaces: [SpaceDTO], current: SpaceDTO) -> AnyView? {
        guard spaces.count > 1 else { return nil }
        return AnyView(
            Menu {
                // Ticked rather than merely highlighted, so the menu says where
                // you are as well as where you could go.
                ForEach(spaces) { space in
                    Button {
                        selectedSpaceID = space.id
                    } label: {
                        if space.id == current.id {
                            Label(space.name, systemImage: "checkmark")
                        } else {
                            Text(space.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current.name)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Shared space: \(current.name). Change space.")
        )
    }

    #if os(iOS)
    /// Clears the originals from the space they were shared out of.
    ///
    /// Offered rather than assumed, and offered *here* — after the copies are
    /// visibly sitting in the destination — because that is the only point at
    /// which agreeing to it is an informed decision rather than a guess about
    /// whether the share worked.
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

    /// The backup bar's state is iOS-only; other platforms get the plain grid.
    @ViewBuilder
    private func timeline(for space: SpaceDTO, switcher: AnyView? = nil) -> some View {
        #if os(iOS)
        TimelineView(
            session: session, space: space,
            engine: engine, backupSettings: $backupSettings,
            spaceSwitcher: switcher,
            onShared: onShared,
            review: review,
            onReviewDone: { review = nil },
            onRemoveOriginals: removeOriginals
        )
        #else
        TimelineView(session: session, space: space, spaceSwitcher: switcher)
        #endif
    }
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
                SpacesView(session: session) {}
            } label: {
                Label("Manage Spaces", systemImage: "person.2.badge.gearshape")
            }
        }

        Section {
            AutoPlayToggle()
            VideoQualityPicker()
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
