import FrameStationAPI
import SwiftUI

#if os(iOS)

/// What arrived, and a way to walk it.
///
/// A move relocates files on the NAS, and "did that actually work?" is a fair
/// question to have about an action that severe. Answering it with a toast that
/// says "8 moved" asks for trust; this instead lands you in the destination and
/// walks you through the eight, one at a time, in the grid where they now live.
/// Synology has nothing like it, and the reason to build it is that a move is
/// exactly the operation people want to see the result of before they believe it.
///
/// Deliberately not a modal. The grid stays live underneath — scroll away,
/// tap a photo, carry on — and the bar simply offers to take you to the next
/// one. Verification you can abandon halfway is verification people will
/// actually use.
@Observable
@MainActor
final class MoveReview {
    /// The assets that landed here, in the order they were moved.
    let assetIDs: [UUID]
    let destinationName: String
    /// Which one is being pointed at, or nil before you start stepping.
    var index: Int?

    init(assetIDs: [UUID], destinationName: String) {
        self.assetIDs = assetIDs
        self.destinationName = destinationName
    }

    var count: Int { assetIDs.count }

    /// The asset currently under review, if any.
    var current: UUID? {
        guard let index, assetIDs.indices.contains(index) else { return nil }
        return assetIDs[index]
    }

    func step(by offset: Int) {
        guard !assetIDs.isEmpty else { return }
        let next = (index ?? -1) + offset
        // Wraps, because the last thing anyone wants at item eight of eight is a
        // dead arrow and no way back to the start.
        index = (next % assetIDs.count + assetIDs.count) % assetIDs.count
    }
}

/// The bar itself: what moved, where it is, and arrows through it.
struct MoveReviewBar: View {
    let review: MoveReview
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            step(-1, symbol: "chevron.left", label: "Previous moved item")
            step(1, symbol: "chevron.right", label: "Next moved item")

            Button(action: onDone) {
                Text("Done").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule(interactive: false, fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var headline: String {
        review.count == 1
            ? "1 item moved here"
            : "\(review.count) items moved here"
    }

    /// Counts from one while stepping, because "3 of 8" is what a person is
    /// checking against — not a zero-based index.
    private var detail: String {
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
