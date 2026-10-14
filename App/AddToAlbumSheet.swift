#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Where selected photos go when you tap "Add to album".
///
/// Everything the Albums page lists under Albums and Shared Albums, in the same
/// order and under the same headings, with "New Album" at the top — picking
/// photos and then wanting somewhere new to put them is the common case, and
/// the server creates an album with contents in one call, so it isn't two
/// round trips.
///
/// Shared libraries are here as well as the albums made in them. The Albums
/// page draws each library as an album, so a library was the "shared album"
/// people went looking for in this list — and this list used to leave every
/// one of them out, which for someone whose only shared album is a library
/// meant a sheet with nothing in it but New Album.
struct AddToAlbumSheet: View {
    let session: AppSession
    /// Placement ids, not asset ids: an album can only hold photos the owner
    /// can already see.
    let spaceAssetIDs: [UUID]
    /// The library the photos are in, which isn't offered as somewhere to put
    /// them.
    var source: SpaceDTO?
    /// Shares the selection into a shared library. Nil where the grid can't,
    /// and the libraries are then left out.
    var onShareToLibrary: ((SpaceDTO) -> Void)?
    let onFinished: (String?) -> Void

    @State private var isLoading = true
    @State private var isWorking = false
    @State private var showNewAlbum = false
    @State private var failure: String?
    /// The library waiting on "Add to …?".
    @State private var confirmingLibrary: SpaceDTO?

    private var store: AlbumStore { session.albumStore() }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && store.albums.isEmpty && libraries.isEmpty {
                    ProgressView()
                } else {
                    List {
                        Section {
                            Button {
                                showNewAlbum = true
                            } label: {
                                Label("New Album", systemImage: "plus.rectangle.on.rectangle")
                            }
                        }

                        if !store.personal.isEmpty {
                            // The same two headings as the Albums page, so an
                            // album is found under the same name in both.
                            Section("Albums") {
                                ForEach(store.personal) { album in
                                    albumRow(album)
                                }
                            }
                        }

                        if !sharedRows.isEmpty {
                            Section {
                                ForEach(sharedRows) { row in
                                    switch row {
                                    case .library(let space):
                                        libraryRow(space)
                                    case .album(let album):
                                        albumRow(album)
                                    }
                                }
                            } header: {
                                Text("Shared Albums")
                            } footer: {
                                // Only where it applies: adding to an album in a
                                // library shares the photos into the library
                                // without asking, where adding to the library
                                // itself asks first.
                                if sharedRows.contains(where: \.isAlbum) {
                                    Text("Photos from your own library are shared with everyone in the album's library too.")
                                }
                            }
                        }

                        if let failure {
                            Section {
                                Label(failure, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(nil) }
                }
            }
            // The same sheet as the Albums page's New Album, with these photos
            // in it from the start: name and contents in one call, so a new
            // album is never briefly empty on the server, and the same choice
            // of who can see it.
            .sheet(isPresented: $showNewAlbum) {
                NewAlbumSheet(
                    session: session, store: store, spaceAssetIDs: spaceAssetIDs
                ) { album in
                    showNewAlbum = false
                    if let album { onFinished("Added to \(album.name)") }
                }
            }
            // Asked, as "Add to Shared Library" asks: adding to a library puts
            // the photos in front of everyone in it and tells them so.
            .confirmationDialog(
                confirmingLibrary.map { "Add \(countedItems) to \($0.name)?" } ?? "",
                isPresented: Binding(
                    get: { confirmingLibrary != nil },
                    set: { if !$0 { confirmingLibrary = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let library = confirmingLibrary {
                    Button("Add") { onShareToLibrary?(library) }
                    Button("Cancel", role: .cancel) { confirmingLibrary = nil }
                }
            } message: {
                Text("Everyone in \(confirmingLibrary?.name ?? "the library") will see them and be notified.")
            }
            .task {
                await load()
            }
        }
    }

    private var title: String {
        countedItems
    }

    private var countedItems: String {
        let count = spaceAssetIDs.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    // MARK: - Shared

    /// One row under Shared Albums: a whole shared library, or an album in one.
    private enum SharedRow: Identifiable {
        case library(SpaceDTO)
        case album(AlbumDTO)

        var id: UUID {
            switch self {
            case .library(let space): space.id
            case .album(let album): album.id
            }
        }

        var isAlbum: Bool {
            if case .album = self { return true }
            return false
        }
    }

    /// The shared libraries these photos can be added to: not the one they're
    /// in, and not one this person may only look at.
    private var libraries: [SpaceDTO] {
        guard onShareToLibrary != nil else { return [] }
        return session.sharedSpaces.filter { $0.id != source?.id && $0.role != .viewer }
    }

    /// Each library, then the albums made in it that you may add to — the
    /// order the Albums page draws them in. Albums of a library this device
    /// hasn't heard of come last: shown, never dropped.
    private var sharedRows: [SharedRow] {
        let albums = store.family.filter(\.mayAdd)
        var rows: [SharedRow] = []
        for space in libraries {
            rows.append(.library(space))
            rows += albums.filter { $0.spaceID == space.id }.map(SharedRow.album)
        }
        rows += albums.filter { album in !libraries.contains { $0.id == album.spaceID } }
            .map(SharedRow.album)
        return rows
    }

    // MARK: - Rows

    private func albumRow(_ album: AlbumDTO) -> some View {
        Button {
            Task { await add(to: album) }
        } label: {
            row(
                title: album.name,
                detail: "\(album.itemCount.formatted()) item\(album.itemCount == 1 ? "" : "s")",
                cover: album.coverAssetID,
                placeholder: album.isFamily ? "person.2.crop.square.stack" : "rectangle.stack"
            )
        }
    }

    private func libraryRow(_ space: SpaceDTO) -> some View {
        let summary = store.libraries.first { $0.id == space.id }
        let members = summary?.memberCount ?? space.memberCount
        let people = members == 1 ? "Just you" : "\(members) people"
        let items = summary.map { "\($0.itemCount.formatted()) item\($0.itemCount == 1 ? "" : "s")" }
        return Button {
            confirmingLibrary = space
        } label: {
            row(
                title: space.name,
                detail: items.map { "\(people) · \($0)" } ?? people,
                cover: summary?.coverAssetID,
                placeholder: "person.2"
            )
        }
    }

    private func row(title: String, detail: String, cover: UUID?, placeholder: String) -> some View {
        HStack(spacing: 12) {
            AlbumRowCover(assetID: cover, placeholder: placeholder, loader: session.loader)
            // `Color`, not the hierarchical styles: inside a button those
            // resolve against the accent tint, and every name came out red.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Loading and adding

    /// The Albums page's own list, asked again, so this sheet and that page
    /// never disagree about what albums there are.
    private func load() async {
        defer { isLoading = false }
        await store.refresh()
    }

    private func add(to album: AlbumDTO) async {
        guard let client = session.client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.addToAlbum(
                album.id, AlbumAssetsRequest(spaceAssetIDs: spaceAssetIDs)
            )
            albumsChanged()
            onFinished("Added to \(album.name)")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The Albums page keeps its list between visits, and an album isn't part
    /// of any library's change log, so nothing else would tell it. Not awaited:
    /// the sheet has nothing to wait for.
    private func albumsChanged() {
        let store = session.albumStore()
        Task { await store.refresh() }
    }
}

/// An album's cover at the size of a list row, or its symbol until there is one.
private struct AlbumRowCover: View {
    let assetID: UUID?
    let placeholder: String
    let loader: ThumbnailLoader?

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetID) {
            guard let assetID, let loader else { return }
            image = await loader.thumbnail(assetID: assetID)
        }
    }
}

/// Presenting the sheet and its confirmation as one modifier.
///
/// Not tidiness: attached inline, these two pushed the timeline's modifier
/// chain past what the type checker will solve, and it gave up with an
/// "unable to type-check in reasonable time" pointed at an unrelated line.
struct AddToAlbumPresentation: ViewModifier {
    let session: AppSession
    let selection: GridSelection
    /// The library the selection is in. See `AddToAlbumSheet.source`.
    var source: SpaceDTO?
    /// See `AddToAlbumSheet.onShareToLibrary`.
    var shareToLibrary: ((SpaceDTO) -> Void)?
    @Binding var isPresented: Bool
    @Binding var result: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AddToAlbumSheet(
                    session: session,
                    spaceAssetIDs: selection.picked.map(\.id),
                    source: source,
                    // The sheet goes first, then the share, which reads and
                    // clears the selection the sheet was showing.
                    onShareToLibrary: shareToLibrary.map { share in
                        { library in
                            isPresented = false
                            share(library)
                        }
                    }
                ) { done in
                    isPresented = false
                    // Only success clears the selection — after a failure the
                    // photos stay picked, ready to try again.
                    if let done {
                        result = done
                        selection.clear()
                    }
                }
            }
            // "Done" rather than "Added": every selection action that reports a
            // count comes through this one alert, and most of them aren't adds.
            .alert("Done", isPresented: Binding(
                get: { result != nil }, set: { if !$0 { result = nil } }
            )) {
                Button("OK") { result = nil }
            } message: {
                Text(result ?? "")
            }
    }
}
#endif
