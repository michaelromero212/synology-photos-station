// Selection is not iOS-only. Only the share sheet underneath it ever was.
#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
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

    /// Favourites everything picked.
    ///
    /// Per-photo and idempotent server-side, so a mixed selection ends up all
    /// favourited rather than toggling each one to its opposite — "Add to
    /// Favorites" on twelve photos should mean twelve favourites, not six.
    func setFavorite(
        _ favorite: Bool, in space: SpaceDTO, client: FrameStationClient?
    ) async -> Int {
        guard let client else { return 0 }
        var changed = 0
        for item in picked {
            do {
                try await client.setFavorite(
                    spaceID: space.id, assetID: item.assetID, favorite
                )
                changed += 1
            } catch {
                continue
            }
        }
        return changed
    }

    /// Re-times everything picked, in one call.
    ///
    /// One request rather than one per photo: each of these moves a file on the
    /// NAS, and a batch half-applied across fifty requests is a much worse thing
    /// to be left holding than one that either largely worked or largely didn't.
    func setCaptureTimes(
        _ plan: [EditCaptureTimeRequest.Item], in space: SpaceDTO,
        client: FrameStationClient?
    ) async -> MediaEditResponse? {
        guard let client, !plan.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false; progress = "" }
        progress = "Re-dating \(plan.count) item\(plan.count == 1 ? "" : "s")…"
        do {
            return try await client.setCaptureTimes(spaceID: space.id, items: plan)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Turns everything picked. Returns as soon as the record is written —
    /// thumbnails are regenerated on the NAS and arrive over delta sync.
    func rotate(
        _ rotation: MediaRotation, in space: SpaceDTO, client: FrameStationClient?
    ) async -> MediaEditResponse? {
        guard let client, !picked.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false; progress = "" }
        progress = "Rotating \(picked.count) item\(picked.count == 1 ? "" : "s")…"
        do {
            return try await client.rotate(
                spaceID: space.id, assetIDs: picked.map(\.assetID), rotation
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func editTags(
        add: [String], remove: [String],
        in space: SpaceDTO, client: FrameStationClient?
    ) async -> Int {
        guard let client, !picked.isEmpty, !(add.isEmpty && remove.isEmpty) else { return 0 }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var changed = 0
        for (index, item) in picked.enumerated() {
            progress = "Tagging \(index + 1) of \(picked.count)…"
            do {
                try await client.editTags(
                    spaceID: space.id, assetID: item.assetID, add: add, remove: remove
                )
                changed += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        return changed
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
struct SelectionBar<MoreContent: View>: View {
    let selection: GridSelection
    let onShare: () -> Void
    let onAddToAlbum: () -> Void
    let onDelete: () -> Void
    /// Menu content, so More opens in place rather than routing back out to
    /// the timeline for a sheet.
    @ViewBuilder let moreMenu: () -> MoreContent

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
                Menu {
                    moreMenu()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "ellipsis").font(.system(size: 20))
                        Text("More").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        // Floating rather than edge-to-edge, because on iOS 26 the tab bar
        // this stands in for floats too — a hard-edged bar in its place reads
        // as a different piece of furniture appearing, not as the same slot
        // changing what it offers.
        .glassBackground(
            in: RoundedRectangle(cornerRadius: 26, style: .continuous),
            interactive: false,
            fallback: .regularMaterial
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
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
#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// The same idea where there is no activity view controller.
///
/// `ShareLink` reaches the system share menu on macOS, which is the round trip
/// that matters there — AirDrop, Mail, Photos — and it needs the files to exist
/// already, which they do: the originals were downloaded before this appeared.
struct ShareSheet: View {
    let items: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.up").font(.largeTitle)
            Text("\(items.count) item\(items.count == 1 ? "" : "s") ready")
                .font(.headline)
            ShareLink(items: items) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}
#endif
#endif

#if !os(tvOS)
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
