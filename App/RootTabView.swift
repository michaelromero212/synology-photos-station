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

    var body: some View {
        // `.tabItem` rather than the iOS 18 `Tab` builder: the deployment
        // target is 17, and this form behaves identically on both.
        TabView {
            NavigationStack {
                if let personal = session.personalSpace {
                    TimelineView(session: session, space: personal)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }

            NavigationStack { AlbumsView(session: session) }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }

            NavigationStack { SharedTab(session: session) }
                .tabItem { Label("Shared", systemImage: "person.2") }

            NavigationStack { MoreView(session: session) }
                .tabItem { Label("More", systemImage: "ellipsis") }
        }
    }
}

/// The family's shared spaces, no longer buried in a dropdown.
///
/// One shared space opens straight into it — a list of one is a wasted tap.
/// Several get a list, because at that point the choice is real.
struct SharedTab: View {
    @Bindable var session: AppSession

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
            } else if shared.count == 1, let only = shared.first {
                TimelineView(session: session, space: only)
            } else {
                List(shared) { space in
                    NavigationLink {
                        TimelineView(session: session, space: space)
                    } label: {
                        Label(space.name, systemImage: "person.2")
                    }
                }
                .navigationTitle("Shared")
            }
        }
        .task { await session.refreshSpaces() }
    }
}

/// Settings and everything that isn't a photo.
struct MoreView: View {
    @Bindable var session: AppSession

    #if os(iOS)
    @State private var showBackup = false
    @State private var backupSettings = BackupSettings.load()
    @Environment(\.backupContainer) private var modelContainer
    @State private var engine: BackupEngine?
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
                BackupSettingsView(
                    session: session, engine: engine, settings: $backupSettings
                ) { showBackup = false }
            }
        }
        .task {
            guard engine == nil, let container = modelContainer else { return }
            engine = BackupEngine(
                container: container, session: session, settings: backupSettings
            )
        }
        #endif
    }

    #if os(iOS)
    /// Mirrors the wording on Synology's own row, because "Photo Backup
    /// Complete" tells you the thing you actually want to know at a glance.
    private var backupStatus: String {
        guard backupSettings.enabled else { return "Photo Backup Off" }
        guard let engine else { return "Photo Backup" }
        if engine.progress.pending > 0 {
            return "Backing Up — \(engine.progress.pending) left"
        }
        return engine.progress.done > 0 ? "Photo Backup Complete" : "Photo Backup"
    }

    private var backupIcon: String {
        guard backupSettings.enabled else { return "icloud.slash" }
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
