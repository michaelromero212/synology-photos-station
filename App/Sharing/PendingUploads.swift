#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos

/// Photos that are on their way to a space but not there yet.
///
/// The grid used to have no idea these existed. Backup had its own queue and
/// drew its own tiles from it; sharing straight from the library had nothing —
/// the picker held the screen behind a progress bar until the last byte landed,
/// and only then let go. Share a four-minute video and you watched a progress
/// bar, then arrived at a grey square, and the photograph appeared some seconds
/// after that when the NAS finished rendering it.
///
/// So the upload moves here, out of the sheet's lifetime, and the sheet closes
/// as soon as it has handed the work over. The grid draws each queued item from
/// the phone's own library immediately — the picture is already on the device,
/// which is the whole reason waiting for the server to send it back was silly —
/// with a badge saying where it has got to.
///
/// One registry for the app rather than one per grid: an upload outlives the
/// view that started it, and has to be visible from the destination as well as
/// the source.
@Observable
@MainActor
final class PendingUploads {
    struct Item: Identifiable {
        let id = UUID()
        let localIdentifier: String
        let capturedAt: Date
        let spaceID: UUID
        var state: UploadState
    }

    private(set) var items: [Item] = []
    /// Bumped whenever a batch finishes, so a grid can refresh once at the end
    /// rather than after each item.
    private(set) var completedBatches = 0

    /// What is still on its way into one space, in capture order.
    func items(in spaceID: UUID) -> [Item] {
        items.filter { $0.spaceID == spaceID }
    }

    func isEmpty(in spaceID: UUID) -> Bool {
        !items.contains { $0.spaceID == spaceID }
    }

    // MARK: - Running a batch

    /// Uploads `assets` into `space`, keeping the grid informed as it goes.
    ///
    /// Serial on purpose, matching the backup queue: a phone pushing six videos
    /// at once over home wifi finishes all six later than it would have finished
    /// them one at a time, and saturates the link for everything else in the
    /// house while it does. See ARCHITECTURE.md §8.
    ///
    /// Returns the number that failed, for whoever wants to say so.
    @discardableResult
    func upload(
        _ assets: [PHAsset], to space: SpaceDTO, client: FrameStationClient
    ) async -> Int {
        let queued = assets.map {
            Item(
                localIdentifier: $0.localIdentifier,
                capturedAt: $0.creationDate ?? Date(),
                spaceID: space.id,
                state: .pending
            )
        }
        items.append(contentsOf: queued)

        var failed = 0
        for (index, asset) in assets.enumerated() {
            let id = queued[index].id
            setState(.uploading, for: id)
            guard let candidate = PhotoLibraryScanner.describe(asset) else {
                failed += 1
                remove(id)
                continue
            }
            do {
                _ = try await AssetUploader.send(
                    asset,
                    descriptor: UploadDescriptor(asset: asset, candidate: candidate),
                    to: space.id,
                    client: client
                )
            } catch {
                failed += 1
            }
            // Removed either way. A landed photo is now the server's to draw,
            // and a failed one has no business sitting in the grid pretending
            // to be on its way — the picker reports the failure instead.
            remove(id)
        }

        completedBatches += 1
        return failed
    }

    private func setState(_ state: UploadState, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
#endif
