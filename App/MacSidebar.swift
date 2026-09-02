#if os(macOS)
import FrameStationAPI
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

    @State private var selection: MacDestination? = .library
    /// The personal library's media types, for the pinned rows.
    ///
    /// Loaded here rather than read from `AlbumsView` because the sidebar
    /// outlives whatever is in the detail pane — these rows have to be there
    /// before you have visited anything.
    @State private var mediaTypes: [CollectionSummary] = []
    /// The toolbar's search field. Owned here because the field is part of the
    /// window rather than of whatever the detail pane happens to be showing.
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // A stack per destination, so pushing into a photo from the Videos
            // row and then switching to Library does not leave you looking at
            // a detail view that belongs to somewhere you have left.
            NavigationStack { detail }
        }
        // In the toolbar, always — the way Photos does it. It was briefly a
        // sidebar row, which made searching a *place you go* rather than
        // something you do to whatever you are already looking at.
        .searchable(text: $query, placement: .toolbar, prompt: "Search Places")
        .task(id: session.personalSpace?.id) { await loadMediaTypes() }
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

            // Each space by name, rather than a "Shared" row that asks again.
            let shared = session.spaces.filter { $0.kind == .shared }
            if !shared.isEmpty {
                Section("Shared") {
                    ForEach(shared) { space in
                        Label(space.name, systemImage: "person.2")
                            .tag(MacDestination.space(space.id))
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
                Label("Manage Spaces", systemImage: "person.2.badge.gearshape")
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
        if !query.isEmpty, let personal = session.personalSpace {
            SearchView(session: session, space: personal, query: $query)
        } else {
            destination
        }
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

        case .space(let id):
            if let space = session.spaces.first(where: { $0.id == id }) {
                TimelineView(session: session, space: space)
            } else {
                // The space was removed while it was on screen.
                ContentUnavailableView {
                    Label("Space Unavailable", systemImage: "person.2.slash")
                } description: {
                    Text("This shared space is no longer available to you.")
                }
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
            SpacesView(session: session) {}
        }
    }

    // MARK: - Loading

    private func loadMediaTypes() async {
        guard let personal = session.personalSpace, let client = session.client else { return }
        // Only on success. A failed refresh that assigned nil would empty the
        // sidebar over a library that is perfectly fine — the same mistake the
        // Albums page made once already.
        if let page = try? await client.collections(spaceID: personal.id) {
            mediaTypes = page.mediaTypes
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
    case space(UUID)
    case mediaType(String)
    case recentlyDeleted
    case spaces
}
#endif
