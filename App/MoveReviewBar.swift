import FrameStationAPI
import SwiftUI

#if os(iOS)

/// What arrived, a way to walk it, and the offer to tidy up afterwards.
///
/// Sharing photos into the family library is the kind of action people want to
/// see the result of before they believe it, and "8 shared" in a toast asks for
/// trust instead of showing evidence. This lands you in the destination and
/// walks you through the eight, one at a time, in the grid where they now live.
/// Synology has nothing like it.
///
/// It also carries the originals, because that is the second half of the
/// decision. Sharing no longer empties photos out of your own library — it used
/// to, and running both decisions together meant the app made the second one
/// silently. So the removal is offered *here*, after you can see the copies
/// arrived, which is the only moment at which it is a safe thing to say yes to.
///
/// Deliberately not a modal. The grid stays live underneath — scroll away, tap
/// a photo, carry on — and the bar simply offers to take you to the next one.
/// Verification you can abandon halfway is verification people will actually
/// use.
@Observable
@MainActor
final class MoveReview {
    /// The assets as they exist **here**, in the order they were shared.
    let assetIDs: [UUID]
    let destinationName: String
    /// The originals, still sitting in the space they were shared from. Nil when
    /// there is nothing sensible to offer removing — sharing from one shared
    /// space to another, say, where "the original" isn't a personal copy.
    let source: Source?
    /// Which one is being pointed at, or nil before you start stepping.
    var index: Int?
    /// Set once the originals have gone, so the offer retires rather than
    /// inviting a second removal of photos that are no longer there.
    var removedOriginals = false
    var isRemoving = false
    var removeError: String?

    struct Source {
        let space: SpaceDTO
        let assetIDs: [UUID]
    }

    init(assetIDs: [UUID], destinationName: String, source: Source? = nil) {
        self.assetIDs = assetIDs
        self.destinationName = destinationName
        self.source = source
    }

    var count: Int { assetIDs.count }

    /// The asset currently under review, if any.
    var current: UUID? {
        guard let index, assetIDs.indices.contains(index) else { return nil }
        return assetIDs[index]
    }

    /// Whether the bar should show the tidy-up offer.
    var canRemoveOriginals: Bool {
        guard let source, !source.assetIDs.isEmpty else { return false }
        return !removedOriginals && source.space.kind == .personal
    }

    func step(by offset: Int) {
        guard !assetIDs.isEmpty else { return }
        let next = (index ?? -1) + offset
        // Wraps, because the last thing anyone wants at item eight of eight is a
        // dead arrow and no way back to the start.
        index = (next % assetIDs.count + assetIDs.count) % assetIDs.count
    }
}

/// The bar itself: one row, the way Apple writes a transient bar.
///
/// It started as two. A status line, then a red "Remove from Personal Space"
/// underneath — which put a destructive action one stray tap from the chevron
/// you were already tapping, in a capsule floating over photographs, at the
/// exact size where a thumb covers half of it. Find-on-page, Recently Deleted,
/// the Files selection bar: none of them stack, and none of them put delete in
/// the open. So the removal moves into an overflow menu, where reaching it
/// costs an open, a tap and a confirmation, and the row itself stays about the
/// one thing it is for — looking at what arrived.
struct MoveReviewBar: View {
    let review: MoveReview
    let onDone: () -> Void
    /// Removes the originals from the space they were shared from. Nil where the
    /// host cannot perform it.
    var onRemoveOriginals: (() -> Void)?

    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            // The one thing allowed to break the single-row rule, because it is
            // exceptional and because a failure people can't read is worse than
            // a bar that grew a line.
            if let error = review.removeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassCapsule(interactive: false, fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog(
            "Remove \(counted) from \(sourceName)?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { onRemoveOriginals?() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(
                "The \(review.count == 1 ? "copy" : "copies") in \(review.destinationName) "
                + "will stay. On the NAS the originals move to #recycle."
            )
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // One line, and it carries the count and the position together
            // rather than spending a second line saying both.
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
                .monospacedDigit()

            Spacer(minLength: 8)

            step(-1, symbol: "chevron.left", label: "Previous shared item")
            step(1, symbol: "chevron.right", label: "Next shared item")

            if review.canRemoveOriginals, onRemoveOriginals != nil {
                overflow
            }

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var overflow: some View {
        Menu {
            Button(role: .destructive) {
                confirmRemoval = true
            } label: {
                Label("Remove Originals from \(sourceName)", systemImage: "trash")
            }
        } label: {
            if review.isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 30)
            } else {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 30)
                    .contentShape(Capsule())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(review.isRemoving)
        .accessibilityLabel("More actions for the items just shared")
    }

    private var sourceName: String {
        review.source?.space.name ?? "your library"
    }

    private var counted: String {
        review.count == 1 ? "1 original" : "\(review.count) originals"
    }

    /// Says the count until you start stepping, then says where you are.
    ///
    /// Both facts in one line rather than one above the other: "1 of 3 shared
    /// here" is the whole status, and counting from one is what a person is
    /// checking against.
    private var label: String {
        if review.removedOriginals {
            return "Originals removed"
        }
        if let index = review.index {
            return "\(index + 1) of \(review.count) shared here"
        }
        return review.count == 1 ? "1 item shared here" : "\(review.count) items shared here"
    }

    private func step(_ offset: Int, symbol: String, label: String) -> some View {
        Button {
            review.step(by: offset)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#endif
