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

    @State private var albums: [AlbumDTO] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var newName = ""
    @State private var showNewAlbum = false
    @State private var failure: String?

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

                        if !albums.isEmpty {
                            Section("Your Albums") {
                                ForEach(albums) { album in
                                    Button {
                                        Task { await add(to: album) }
                                    } label: {
                                        HStack {
                                            Label(album.name, systemImage: "rectangle.stack")
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text("\(album.itemCount)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
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
            .alert("New Album", isPresented: $showNewAlbum) {
                TextField("Album name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") { Task { await create() } }
            } message: {
                Text(title)
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

    private func load() async {
        defer { isLoading = false }
        guard let client = session.client else { return }
        albums = (try? await client.albums().albums) ?? []
    }

    private func add(to album: AlbumDTO) async {
        guard let client = session.client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.addToAlbum(
                album.id, AlbumAssetsRequest(spaceAssetIDs: spaceAssetIDs)
            )
            onFinished("Added to \(album.name)")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty, let client = session.client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            // Name and contents in one call, so a new album is never briefly
            // empty on the server.
            let album = try await client.createAlbum(
                CreateAlbumRequest(name: name, spaceAssetIDs: spaceAssetIDs)
            )
            onFinished("Added to \(album.name)")
        } catch {
            failure = error.localizedDescription
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
