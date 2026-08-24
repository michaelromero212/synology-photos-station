import FrameStationAPI
import FrameStationKit
import SwiftUI

#if os(iOS)

/// Choosing which shared space a selection should go into, and confirming it
/// before it goes.
///
/// Only shared spaces are offered, and never the one you are already in.
/// Synology's version of this screen starts by asking you to pick a *source*,
/// which is a question the app already knows the answer to — you are standing in
/// the source, with the photos selected. So this opens straight on destinations.
///
/// Personal spaces are absent on purpose: adding into someone else's own library
/// would put your photos in their private tree, and adding into your own is what
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
                        Label("Nowhere to add these", systemImage: "person.2")
                    } description: {
                        Text(
                            "Photos can only be added to a shared space. "
                            + "Create one and everyone in it sees the same photos."
                        )
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Add To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        // Still confirmed, though it no longer takes anything away. What it
        // does instead is publish: everyone in that space sees these photos and
        // gets told about them, and that is worth a deliberate second tap.
        .confirmationDialog(
            pending.map { "Add \(countedItems) to \($0.name)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button("Add") { onConfirm(pending) }
                Button("Cancel", role: .cancel) { self.pending = nil }
            }
        } message: {
            Text(
                "Everyone in \(pending?.name ?? "the space") will see them and be notified. "
                + "Your copies stay in \(source.name) — you can remove them afterwards if you want."
            )
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
