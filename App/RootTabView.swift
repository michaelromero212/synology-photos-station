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
    #endif

    var body: some View {
        // `.tabItem` rather than the iOS 18 `Tab` builder: the deployment
        // target is 17, and this form behaves identically on both.
        TabView {
            NavigationStack {
                if let personal = session.personalSpace {
                    photosTimeline(personal)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }

            NavigationStack { AlbumsView(session: session) }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }

            NavigationStack { sharedTab }
                .tabItem { Label("Shared", systemImage: "person.2") }

            NavigationStack { moreTab }
            .tabItem { Label("More", systemImage: "ellipsis") }
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
        SharedTab(session: session, engine: engine, backupSettings: $backupSettings)
        #else
        SharedTab(session: session)
        #endif
    }

    @ViewBuilder
    private func photosTimeline(_ space: SpaceDTO) -> some View {
        #if os(iOS)
        TimelineView(
            session: session, space: space,
            engine: engine, backupSettings: $backupSettings
        )
        #else
        TimelineView(session: session, space: space)
        #endif
    }

    #if os(iOS)
    private var engineIfReady: BackupEngine? { engine }
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

    /// Which shared space is on screen. Nil until the first list of spaces
    /// arrives, then whichever the person last picked.
    @State private var selectedSpaceID: UUID?

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

    /// The backup bar's state is iOS-only; other platforms get the plain grid.
    @ViewBuilder
    private func timeline(for space: SpaceDTO, switcher: AnyView? = nil) -> some View {
        #if os(iOS)
        TimelineView(
            session: session, space: space,
            engine: engine, backupSettings: $backupSettings,
            spaceSwitcher: switcher
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
        List {
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
