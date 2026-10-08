import FrameStationAPI
import SwiftUI

#if os(iOS)

/// What arrived, a way to walk it, and the offer to tidy up afterward.
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
    /// The assets as they exist **here**, in the order they were shared: what
    /// arrived, then what turned out to be here already.
    let assetIDs: [UUID]
    /// The album they landed in. Only its grid shows this review.
    let destinationID: UUID
    let destinationName: String
    /// How many arrived with this share.
    let newCount: Int
    /// How many were in the album before it.
    ///
    /// Counted even when the server can't say which they were — one that
    /// predates `alreadySharedAssetIDs` — so the bar can still say "already
    /// here" instead of "0 shared", which is what made a repeated share look
    /// like a broken one.
    let alreadyCount: Int
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

    init(
        assetIDs: [UUID], destinationID: UUID, destinationName: String,
        newCount: Int, alreadyCount: Int = 0, source: Source? = nil
    ) {
        self.assetIDs = assetIDs
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.newCount = newCount
        self.alreadyCount = alreadyCount
        self.source = source
    }

    /// How many the bar can walk: those whose ids came back.
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

/// The review a share hands to the album it landed in.
///
/// An object the album's grid reads, rather than an optional passed down to
/// it. The album is a navigation destination, and SwiftUI can build one from
/// a closure left over from an earlier pass of the tab view's body. Measured:
/// the album built while following a share read the path and the tab as they
/// were before the share began. A review handed down as a value could be just
/// as stale. The grid observes this object directly, so what it draws is
/// current.
@Observable
@MainActor
final class ShareReviews {
    private(set) var current: MoveReview?

    func begin(_ review: MoveReview) { current = review }

    func end() { current = nil }

    /// The review to show in a space's grid. Only the album the photos landed
    /// in shows it. It used to be handed to every shared album, so opening a
    /// different one put "shared here" over photos that were never shared to it.
    func review(for spaceID: UUID) -> MoveReview? {
        current?.destinationID == spaceID ? current : nil
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
                "The \(originals == 1 ? "copy" : "copies") in \(review.destinationName) "
                + "will stay. The \(originals == 1 ? "original goes" : "originals go") to "
                + "Recently Deleted on your NAS for \(Retention.days) days."
            )
        }
    }

    /// The originals the removal would take: only those of what this share
    /// added. Photos that were already in the album came from some earlier
    /// share, and this one has no business deciding about their originals.
    private var originals: Int {
        review.source?.assetIDs.count ?? 0
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

            // Only when there is something to point at. A server too old to say
            // which photos were already here leaves nothing to walk, and arrows
            // that do nothing are worse than none.
            if review.count > 0 {
                step(-1, symbol: "chevron.left", label: "Previous shared item")
                step(1, symbol: "chevron.right", label: "Next shared item")
            }

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
        originals == 1 ? "1 original" : "\(originals) originals"
    }

    /// Says the count until you start stepping, then says where you are.
    ///
    /// Both facts in one line rather than one above the other: "1 of 3 shared
    /// here" is the whole status, and counting from one is what a person is
    /// checking against.
    ///
    /// What was already here is said as such. Sharing photos that were in the
    /// album already used to read "0 items shared here", and with nothing new
    /// in the grid either, the only conclusion left was that sharing had
    /// stopped working.
    private var label: String {
        if review.removedOriginals {
            return "Originals removed"
        }
        if let index = review.index {
            return review.alreadyCount == 0
                ? "\(index + 1) of \(review.count) shared here"
                : "\(index + 1) of \(review.count) here"
        }
        switch (review.newCount, review.alreadyCount) {
        case (let new, 0):
            return new == 1 ? "1 item shared here" : "\(new) items shared here"
        case (0, 1):
            return "Already here"
        case (0, 2):
            return "Both already here"
        case (0, let already):
            return "All \(already) already here"
        case (let new, let already):
            return "\(new) new, \(already) already here"
        }
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
