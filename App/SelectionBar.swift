#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos
import SwiftUI

/// What the user has picked in the grid, and the things they can do with it.
///
/// Kept out of the view so the grid doesn't have to own the work — the actions
/// outlive the sheet that starts them, and a delete that is halfway through a
/// list must not stop because a row scrolled away.
@Observable
@MainActor
final class GridSelection {
    var isActive = false
    /// `space_assets.id` — the placement, which is what a removal acts on.
    private(set) var picked: [TimelineItem] = []

    private(set) var isWorking = false
    private(set) var progress = ""
    private(set) var lastError: String?

    var count: Int { picked.count }

    func contains(_ item: TimelineItem) -> Bool {
        picked.contains { $0.id == item.id }
    }

    func toggle(_ item: TimelineItem) {
        if let index = picked.firstIndex(where: { $0.id == item.id }) {
            picked.remove(at: index)
        } else {
            picked.append(item)
        }
    }

    func begin(with item: TimelineItem) {
        isActive = true
        if !contains(item) { picked.append(item) }
    }

    func clear() {
        picked.removeAll()
        isActive = false
        lastError = nil
    }

    // MARK: - Actions

    /// Removes every selected photo from this library.
    func remove(from space: SpaceDTO, client: FrameStationClient?) async -> Bool {
        guard let client, !picked.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var failed = 0
        for (index, item) in picked.enumerated() {
            progress = "Removing \(index + 1) of \(picked.count)…"
            do {
                try await client.removeAsset(spaceID: space.id, assetID: item.assetID)
            } catch {
                failed += 1
                lastError = error.localizedDescription
            }
        }
        // Keep the selection when something failed, so the user can see what is
        // still there and try again rather than guessing.
        if failed == 0 { clear() }
        return failed == 0
    }

    /// Downloads the originals so they can be handed to the share sheet —
    /// which is how a photo gets back into the iPhone's own library, via
    /// "Save Image".
    func downloadOriginals(
        from space: SpaceDTO, client: FrameStationClient?
    ) async -> [URL] {
        guard let client, !picked.isEmpty else { return [] }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var files: [URL] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        for (index, item) in picked.enumerated() {
            progress = "Preparing \(index + 1) of \(picked.count)…"
            do {
                let data = try await client.originalData(assetID: item.assetID)
                // A real filename matters: it is what the share sheet shows and
                // what lands in Files if the user saves it there.
                let name = item.mediaType == .video
                    ? "\(item.assetID.uuidString.prefix(8)).mov"
                    : "\(item.assetID.uuidString.prefix(8)).jpg"
                let file = directory.appendingPathComponent(name)
                try data.write(to: file)
                files.append(file)
            } catch {
                lastError = error.localizedDescription
            }
        }
        return files
    }
}

/// The contextual bar that replaces the tab bar while selecting.
struct SelectionBar: View {
    let selection: GridSelection
    let onShare: () -> Void
    let onAddToAlbum: () -> Void
    let onDelete: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if selection.isWorking, !selection.progress.isEmpty {
                Text(selection.progress)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                action("Share", "square.and.arrow.up", onShare)
                action("Add to album", "rectangle.stack.badge.plus", onAddToAlbum)
                action("Delete", "trash", onDelete)
                action("More", "ellipsis", onMore)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .disabled(selection.count == 0 || selection.isWorking)
    }

    private func action(
        _ title: String, _ symbol: String, _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// Wraps `UIActivityViewController` so "Save Image" puts a photo back in the
/// iPhone's own library — the round trip the user asked for.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#if os(iOS)
/// The circle on each tile while selecting, numbered the way Photos does it.
struct SelectionMark: View {
    let isPicked: Bool

    var body: some View {
        ZStack {
            Circle().fill(isPicked ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.black.opacity(0.25)))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if isPicked {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }
}
#endif
