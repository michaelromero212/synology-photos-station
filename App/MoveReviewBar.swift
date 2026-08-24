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

/// The bar itself: what landed, where it is, arrows through it, and the offer to
/// clear the originals once you've looked.
struct MoveReviewBar: View {
    let review: MoveReview
    let onDone: () -> Void
    /// Removes the originals from the space they were shared from. Nil where the
    /// host cannot perform it.
    var onRemoveOriginals: (() -> Void)?

    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 8) {
            mainRow
            if review.canRemoveOriginals, onRemoveOriginals != nil {
                removalRow
            }
            if let error = review.removeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule(interactive: false, fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Said plainly, because this is the destructive half of the flow and the
        // photos it removes are the copies on the phone's own library, not the
        // ones just shared.
        .confirmationDialog(
            "Remove \(counted) from \(review.source?.space.name ?? "your library")?",
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

    private var mainRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            step(-1, symbol: "chevron.left", label: "Previous shared item")
            step(1, symbol: "chevron.right", label: "Next shared item")

            Button(action: onDone) {
                Text("Done").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
    }

    /// A second line rather than another button in the first: the row above is
    /// about looking, this one is about deleting, and a destructive action
    /// crammed in beside two chevrons is one mis-tap away from a mistake.
    private var removalRow: some View {
        HStack(spacing: 10) {
            Divider().frame(height: 1).hidden()
            Button {
                confirmRemoval = true
            } label: {
                HStack(spacing: 6) {
                    if review.isRemoving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(review.isRemoving ? "Removing…" : "Remove from \(sourceName)")
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(review.isRemoving)
            Spacer(minLength: 0)
        }
    }

    private var sourceName: String {
        review.source?.space.name ?? "your library"
    }

    private var counted: String {
        review.count == 1 ? "1 original" : "\(review.count) originals"
    }

    private var headline: String {
        review.count == 1
            ? "1 item shared here"
            : "\(review.count) items shared here"
    }

    /// Counts from one while stepping, because "3 of 8" is what a person is
    /// checking against — not a zero-based index.
    private var detail: String {
        if review.removedOriginals {
            return "Originals removed from \(sourceName)"
        }
        if let index = review.index {
            return "Showing \(index + 1) of \(review.count)"
        }
        return "Step through to check them"
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
