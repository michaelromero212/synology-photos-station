import FrameStationAPI
import FrameStationKit
import SwiftUI

#if os(iOS)

/// Choosing where a selection of photos should go, and confirming it before it
/// goes there.
///
/// Only shared spaces are offered, and never the one you are already in.
/// Synology's version of this screen starts by asking you to pick a *source*,
/// which is a question the app already knows the answer to — you are standing in
/// the source, with the photos selected. So this opens straight on destinations.
///
/// Personal spaces are absent on purpose: moving into someone's own library
/// would put your photos in their private tree, and moving into your own is what
/// you already have. The whole verb exists for putting things in front of the
/// family.
struct MoveToSheet: View {
    @Bindable var session: AppSession
    let source: SpaceDTO
    let count: Int
    let onCancel: () -> Void
    /// Called with the chosen destination once the move is confirmed.
    let onConfirm: (SpaceDTO) -> Void

    @State private var pending: SpaceDTO?

    private var destinations: [SpaceDTO] {
        session.spaces.filter { $0.kind == .shared && $0.id != source.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty {
                    ContentUnavailableView {
                        Label("Nowhere to move these", systemImage: "person.2")
                    } description: {
                        Text(
                            "Photos can only be moved into a shared space. "
                            + "Create one and everyone in it sees the same photos."
                        )
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        // Said plainly, and said before it happens: a move is the one action
        // here that takes photos *out* of where they are, and the sentence has
        // to carry that or people will read it as sharing.
        .confirmationDialog(
            pending.map { "Move \(countedItems) to \($0.name)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button("Move") { onConfirm(pending) }
                Button("Cancel", role: .cancel) { self.pending = nil }
            }
        } message: {
            Text("They'll leave \(source.name) and live in the shared space instead. On the NAS the files move too.")
        }
    }

    private var countedItems: String {
        count == 1 ? "1 item" : "\(count) items"
    }

    private var list: some View {
        List(destinations) { space in
            Button {
                pending = space
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(space.name)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        }
    }
}

#endif
