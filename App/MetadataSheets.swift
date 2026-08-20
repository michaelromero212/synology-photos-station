#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Adding and removing tags, for one photo or for everything selected.
///
/// Two sections that each mean one thing, rather than one list of checkboxes:
/// a selection of twelve photos need not agree on what it is tagged. "Add
/// Beach" is something you can mean for all twelve and so is "remove Beach",
/// but "Beach: on or off" is not a state any single control can honestly show.
struct TagEditorSheet: View {
    let session: AppSession
    let space: SpaceDTO
    let title: String
    /// What the photo already carries. Empty for a selection, where the photos
    /// need not agree — the library's own tags stand in for the remove list.
    let current: [String]
    let apply: ([String], [String]) async -> Int
    let onFinished: (String?) -> Void

    @State private var entry = ""
    @State private var adding: [String] = []
    @State private var removing: [String] = []
    @State private var library: [String] = []
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                addSection
                if !suggestions.isEmpty { suggestionSection }
                if !removable.isEmpty { removeSection }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(adding.isEmpty && removing.isEmpty)
                }
            }
            .task { await loadLibraryTags() }
        }
    }

    // MARK: - Sections

    private var addSection: some View {
        Section("Add") {
            HStack {
                // Both of these are keyboard affordances, and a Mac has a
                // hardware one — the modifiers simply don't exist there.
                TextField("New tag", text: $entry)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    #endif
                    .onSubmit(commitEntry)
                Button("Add", action: commitEntry)
                    .disabled(trimmedEntry.isEmpty)
            }
            ForEach(adding, id: \.self) { tag in
                Button { adding.removeAll { $0 == tag } } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(tag).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var suggestionSection: some View {
        Section("In \(space.name)") {
            ForEach(suggestions, id: \.self) { tag in
                Button { adding.append(tag) } label: {
                    HStack {
                        Image(systemName: "tag").foregroundStyle(.secondary)
                        Text(tag).foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var removeSection: some View {
        Section {
            ForEach(removable, id: \.self) { tag in
                Button { toggleRemoval(tag) } label: {
                    HStack {
                        Image(systemName: removing.contains(tag) ? "minus.circle.fill" : "circle")
                            .foregroundStyle(removing.contains(tag) ? .red : .secondary)
                        Text(tag)
                            .foregroundStyle(.primary)
                            .strikethrough(removing.contains(tag))
                        Spacer()
                    }
                }
            }
        } header: {
            Text(current.isEmpty ? "Remove" : "On This Photo")
        } footer: {
            if current.isEmpty {
                Text("Removing a tag takes it off every selected photo that has it.")
            }
        }
    }

    // MARK: - State

    private var trimmedEntry: String {
        entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Library tags worth offering: not already staged, and not already on the
    /// photo — those belong in the remove section instead.
    private var suggestions: [String] {
        library.filter { tag in
            !adding.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                && !current.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// This photo's own tags, or — for a selection, where they may differ —
    /// everything the library uses.
    private var removable: [String] {
        current.isEmpty ? library : current
    }

    private func commitEntry() {
        let name = trimmedEntry
        guard !name.isEmpty else { return }
        entry = ""
        guard !adding.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        adding.append(name)
        // Staging an add and a removal of the same name would have the server
        // do both, in an order the user never chose.
        removing.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func toggleRemoval(_ tag: String) {
        if let index = removing.firstIndex(of: tag) {
            removing.remove(at: index)
        } else {
            removing.append(tag)
            adding.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    private func loadLibraryTags() async {
        guard let client = session.client else { return }
        library = (try? await client.spaceTags(spaceID: space.id)) ?? []
    }

    private func save() {
        // Anything typed but not yet added is still what the user meant.
        commitEntry()
        Task {
            isWorking = true
            failure = nil
            let count = await apply(adding, removing)
            isWorking = false
            guard count > 0 else {
                failure = "Couldn't change the tags."
                return
            }
            let noun = count == 1 ? "item" : "items"
            onFinished("Tags updated on \(count) \(noun)")
        }
    }
}

/// Presenting both editors as one modifier.
///
/// Same reason as `AddToAlbumPresentation`: attached inline, these push the
/// timeline's modifier chain past what the type checker will solve, and it
/// gives up pointing at an unrelated line.
struct MetadataPresentation: ViewModifier {
    let session: AppSession
    let space: SpaceDTO
    let selection: GridSelection
    @Binding var showTags: Bool
    @Binding var result: String?

    func body(content: Content) -> some View {
        content
            // Only success clears the selection: after a failure the photos
            // stay picked, ready to try again.
            .sheet(isPresented: $showTags) {
                TagEditorSheet(
                    session: session, space: space, title: countTitle, current: []
                ) { add, remove in
                    await selection.editTags(
                        add: add, remove: remove, in: space, client: session.client
                    )
                } onFinished: { done in
                    showTags = false
                    if let done {
                        result = done
                        selection.clear()
                    }
                }
            }
    }

    private var countTitle: String {
        "\(selection.count) item\(selection.count == 1 ? "" : "s")"
    }
}
#endif
