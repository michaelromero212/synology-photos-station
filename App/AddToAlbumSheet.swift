#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Where selected photos go when you tap "Add to album".
///
/// Existing albums first, with "New Album" at the top — picking photos and
/// then wanting somewhere new to put them is the common case, and the server
/// creates an album with contents in one call, so it isn't two round trips.
struct AddToAlbumSheet: View {
    let session: AppSession
    /// Placement ids, not asset ids: an album can only hold photos the owner
    /// can already see.
    let spaceAssetIDs: [UUID]
    let onFinished: (String?) -> Void

    @State private var isLoading = true
    @State private var isWorking = false
    @State private var showNewAlbum = false
    @State private var failure: String?

    private var store: AlbumStore { session.albumStore() }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
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
                                    row(album, systemImage: "rectangle.stack")
                                }
                            }
                        }

                        // Only the ones you can add to. Adding shares a photo
                        // with the whole library, which the footer says before
                        // anyone taps.
                        let family = store.family.filter(\.mayAdd)
                        if !family.isEmpty {
                            Section {
                                ForEach(family) { album in
                                    row(album, systemImage: "person.2.crop.square.stack")
                                }
                            } header: {
                                Text("Shared Albums")
                            } footer: {
                                Text("Photos from your own library are shared with everyone in the album's library too.")
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
            .task {
                await load()
            }
        }
    }

    private var title: String {
        let count = spaceAssetIDs.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private func row(_ album: AlbumDTO, systemImage: String) -> some View {
        Button {
            Task { await add(to: album) }
        } label: {
            HStack {
                Label(album.name, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(album.itemCount)")
                    .foregroundStyle(.secondary)
            }
        }
    }

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

/// Presenting the sheet and its confirmation as one modifier.
///
/// Not tidiness: attached inline, these two pushed the timeline's modifier
/// chain past what the type checker will solve, and it gave up with an
/// "unable to type-check in reasonable time" pointed at an unrelated line.
struct AddToAlbumPresentation: ViewModifier {
    let session: AppSession
    let selection: GridSelection
    @Binding var isPresented: Bool
    @Binding var result: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AddToAlbumSheet(
                    session: session,
                    spaceAssetIDs: selection.picked.map(\.id)
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
