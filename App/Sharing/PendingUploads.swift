#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos
import SwiftData

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
    /// Bumped as each item lands, so a grid can close the gap between a pending
    /// tile retiring and its server row arriving without waiting for the whole
    /// batch. Readers debounce it — see `TimelineView.scheduleLandingRefresh`.
    private(set) var completedItems = 0

    /// Where the queue is written down. Set once, at launch.
    ///
    /// Optional because this object is built with the session, long before the
    /// SwiftData container exists — and because an unopenable store must
    /// degrade to the old in-memory behaviour rather than take the app with it.
    /// Everything below works either way; without a context the queue simply
    /// does not survive termination, which is exactly where this started.
    private var context: ModelContext?

    /// Adopts the store and picks up anything a previous run left behind.
    ///
    /// The resume is the whole point. A share of two hundred photos that was
    /// interrupted by iOS reclaiming the app used to leave nothing at all —
    /// no record of what was outstanding, and no way to finish it. Now the
    /// rows are still there and the batch carries on.
    func attach(container: ModelContainer, client: FrameStationClient) async {
        guard context == nil else { return }
        let context = ModelContext(container)
        self.context = context

        // Anything left `uploading` was in flight when we died. Back to
        // pending: the server keeps the chunks it already accepted, so the
        // probe resumes from there rather than starting the file again.
        let rows = (try? context.fetch(FetchDescriptor<ManualUpload>())) ?? []
        guard !rows.isEmpty else { return }
        for row in rows where row.state == .uploading { row.state = .pending }
        try? context.save()

        items = rows.filter { $0.state != .failed }.map {
            Item(localIdentifier: $0.localIdentifier, capturedAt: $0.capturedAt,
                 spaceID: $0.spaceID, state: .pending)
        }
        for spaceID in Set(items.map(\.spaceID)) {
            await drain(spaceID: spaceID, client: client)
        }
    }

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
        // Written down before a byte moves, so an interruption leaves a record
        // rather than a gap.
        if let context {
            for item in queued {
                context.insert(
                    ManualUpload(
                        localIdentifier: item.localIdentifier,
                        spaceID: item.spaceID,
                        capturedAt: item.capturedAt
                    )
                )
            }
            try? context.save()
        }

        let failed = await drain(spaceID: space.id, client: client)
        completedBatches += 1
        return failed
    }

    /// Runs the lanes until this space has nothing outstanding.
    ///
    /// Shared by a fresh batch and by the resume at launch, so an interrupted
    /// share finishes exactly the way it would have if nothing had happened.
    @discardableResult
    private func drain(spaceID: UUID, client: FrameStationClient) async -> Int {
        await withTaskGroup(of: Int.self) { group -> Int in
            for _ in 0..<UploadConcurrency.maxLanes {
                group.addTask { @MainActor [weak self] in
                    await self?.drainBatchLane(spaceID: spaceID, client: client) ?? 0
                }
            }
            return await group.reduce(0, +)
        }
    }

    /// One lane: claim the next pending row for this space, send it, repeat.
    /// Returns how many it failed, which the pool sums into the batch total.
    private func drainBatchLane(spaceID: UUID, client: FrameStationClient) async -> Int {
        var failed = 0
        while let claimed = claimNext(in: spaceID) {
            // The tile retires either way. A landed photo is now the server's
            // to draw, and one that has given up has no business sitting in the
            // grid pretending to be on its way — the picker reports the failure
            // instead.
            defer {
                remove(claimed.id)
                completedItems += 1
            }
            guard let asset = PhotoLibraryScanner.asset(for: claimed.localIdentifier),
                  let candidate = PhotoLibraryScanner.describe(asset) else {
                // Gone from the camera roll between queueing and sending.
                // Nothing to retry and nothing to report as broken.
                forget(localIdentifier: claimed.localIdentifier, spaceID: spaceID)
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
                forget(localIdentifier: claimed.localIdentifier, spaceID: spaceID)
            } catch {
                // Three attempts, matching the backup queue. A share that hit
                // one bad moment on the wifi used to be reported as a failure
                // and forgotten; now it is still written down, and the next
                // launch picks it up.
                failed += 1
                record(
                    failure: error, localIdentifier: claimed.localIdentifier,
                    spaceID: spaceID
                )
            }
        }
        return failed
    }

    /// Drops the row for a photo that no longer needs one.
    private func forget(localIdentifier: String, spaceID: UUID) {
        guard let context, let row = row(localIdentifier: localIdentifier, spaceID: spaceID)
        else { return }
        context.delete(row)
        try? context.save()
    }

    private func record(failure: any Error, localIdentifier: String, spaceID: UUID) {
        guard let context, let row = row(localIdentifier: localIdentifier, spaceID: spaceID)
        else { return }
        row.attempts += 1
        row.lastError = failure.localizedDescription
        // Kept as pending while there are attempts left, so `attach` picks it
        // up next launch; parked as failed once there are not, so it stops
        // being retried forever and can still be found.
        row.state = row.attempts < 3 ? .pending : .failed
        try? context.save()
    }

    private func row(localIdentifier: String, spaceID: UUID) -> ManualUpload? {
        guard let context else { return nil }
        let key = ManualUpload.key(localIdentifier: localIdentifier, spaceID: spaceID)
        var descriptor = FetchDescriptor<ManualUpload>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
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
        // Marked on disk too, so a run that dies mid-file is recognisable as
        // one that was in flight rather than one that never started.
        if let row = row(
            localIdentifier: items[index].localIdentifier, spaceID: spaceID
        ) {
            row.state = .uploading
            try? context?.save()
        }
        return items[index]
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
#endif
