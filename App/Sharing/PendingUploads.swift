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
    /// Runs a bounded pool of `UploadConcurrency.maxLanes` lanes — the same pool
    /// the backup queue uses now — so a share of several videos moves a few at a
    /// time instead of single-file, while the bound keeps it from saturating
    /// home wifi for the rest of the house. (It used to be serial "to match the
    /// backup queue"; the backup queue went parallel, so this follows.)
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

        let failed = await withTaskGroup(of: Int.self) { group -> Int in
            for _ in 0..<UploadConcurrency.maxLanes {
                group.addTask { @MainActor [weak self] in
                    await self?.drainBatchLane(spaceID: space.id, client: client) ?? 0
                }
            }
            return await group.reduce(0, +)
        }

        completedBatches += 1
        return failed
    }

    /// One lane: claim the next pending row for this space, send it, repeat.
    /// Returns how many it failed, which the pool sums into the batch total.
    private func drainBatchLane(spaceID: UUID, client: FrameStationClient) async -> Int {
        var failed = 0
        while let claimed = claimNext(in: spaceID) {
            // Removed either way. A landed photo is now the server's to draw,
            // and a failed one has no business sitting in the grid pretending to
            // be on its way — the picker reports the failure instead.
            defer { remove(claimed.id) }
            guard let asset = PhotoLibraryScanner.asset(for: claimed.localIdentifier),
                  let candidate = PhotoLibraryScanner.describe(asset) else {
                failed += 1
                continue
            }
            do {
                let result = try await AssetUploader.send(
                    asset,
                    descriptor: UploadDescriptor(asset: asset, candidate: candidate),
                    to: spaceID,
                    client: client
                )
                // The server has the file and will get to a thumbnail of it in
                // its own time; this phone has one now. See `LocalOriginals`.
                if let assetID = result.assetID {
                    LocalOriginals.shared.record(
                        assetID: assetID, localIdentifier: claimed.localIdentifier
                    )
                }
            } catch {
                failed += 1
            }
        }
        return failed
    }

    /// Marks the next pending row for this space in-flight and returns it —
    /// atomic because it is synchronous on the main actor, so no two lanes take
    /// the same row. The asset is refetched by local id inside the lane rather
    /// than captured, so no `PHAsset` crosses a task boundary.
    private func claimNext(in spaceID: UUID) -> Item? {
        guard let index = items.firstIndex(where: {
            $0.spaceID == spaceID && $0.state == .pending
        }) else { return nil }
        items[index].state = .uploading
        return items[index]
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
#endif
