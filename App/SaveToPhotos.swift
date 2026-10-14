#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import Foundation
#if os(iOS)
import Photos
import SwiftData
import UIKit
#endif

/// An original fetched from the NAS to hand to the share sheet, and which photo
/// it is: what saving it back to the phone needs to know to keep backup from
/// sending it up again. See `PhotoLibrarySaver`.
struct DownloadedOriginal: Sendable {
    let url: URL
    let assetID: UUID
    let mediaType: MediaType
    let capturedAt: Date

    /// Fetches `item`'s original into `folder`, straight to disk.
    static func fetch(
        _ item: TimelineItem, into folder: URL, client: FrameStationClient
    ) async throws -> DownloadedOriginal {
        // A real name matters: it is what the share sheet shows and what lands
        // in Files if the original is saved there.
        let url = try await client.downloadOriginal(
            assetID: item.assetID, to: folder,
            name: String(item.assetID.uuidString.prefix(8)),
            fallbackExtension: item.mediaType == .video ? "mov" : "jpg"
        )
        return DownloadedOriginal(
            url: url, assetID: item.assetID, mediaType: item.mediaType,
            capturedAt: item.capturedAt
        )
    }

    /// A new folder for one share's originals, with any left by earlier shares
    /// cleared first. The share sheet may still be reading a share's files
    /// when it closes, so they're let go of at the next one rather than then —
    /// which also keeps a few gigabytes of video from sitting in the phone's
    /// storage until iOS gets round to clearing it.
    static func freshFolder() -> URL {
        let shares = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameStation Shares", isDirectory: true)
        try? FileManager.default.removeItem(at: shares)
        let folder = shares.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

#if os(iOS)
/// Puts originals from the NAS into this iPhone's photo library in a way
/// backup recognizes, so a photo saved back to the phone is never sent up again
/// as a new one.
///
/// It used to be: the share sheet's own Save Image rewrote a photo's metadata
/// on its way into Photos — fifty bytes, measured — and backup, seeing a new
/// photo with new bytes, sent it to the NAS, which kept it as a second copy.
/// Every photo re-downloaded became a duplicate.
///
/// Three things now stand in the way, each enough on its own for the case it
/// covers. The file goes into Photos as it came, byte for byte, so the NAS
/// recognizes it whoever sends it — this phone, or another of the family's
/// devices that iCloud brings it to. It's written into backup's ledger as
/// already on the NAS, in the same moment PhotoKit creates it, so backup never
/// reads it at all. And the background extension is told it's handled, so iOS
/// never uploads it while the app is closed.
@MainActor
enum PhotoLibrarySaver {
    enum Failure: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            "FrameStation can't add to your photo library. Allow it in Settings, then try again."
        }
    }

    static func save(_ originals: [DownloadedOriginal]) async throws {
        guard !originals.isEmpty else { return }
        guard await mayAdd() else { throw Failure.notAllowed }

        let container = BackupStore.container
        let created = CreatedAssets()
        try await PHPhotoLibrary.shared().performChanges {
            // Inside the change, so the rows are in the ledger before the
            // library announces the photos. Written after it, backup's change
            // observer could reach a photo first and queue it.
            let ledger = ModelContext(container)
            for original in originals {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = original.url.lastPathComponent
                request.addResource(
                    with: original.mediaType == .video ? .video : .photo,
                    fileURL: original.url, options: options
                )
                guard let id = request.placeholderForCreatedAsset?.localIdentifier else { continue }
                created.append(id)
                ledger.insert(BackupItem(alreadyOnNAS: original, localIdentifier: id))
            }
            try? ledger.save()
        }

        // And the extension's list, read before it sends anything.
        let ids = created.identifiers
        BackgroundUploadShared.updateProgress { progress in
            for id in ids { progress.handled[id] = Date() }
        }
        Diagnostics.shared.log(
            .backup, "saved \(ids.count) original(s) to Photos, recorded as already on the NAS"
        )
    }

    /// Whether this app may add to the library, asking the first time.
    /// Full access, which backup asks for, includes adding.
    private static func mayAdd() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let answer = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return answer == .authorized || answer == .limited
        default:
            return false
        }
    }
}

/// The identifiers PhotoKit gives the photos it's creating, collected inside a
/// change block that runs on PhotoKit's own queue.
private final class CreatedAssets: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func append(_ id: String) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    var identifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

extension BackupItem {
    /// A photo saved from the NAS, entered in the ledger as one backup has
    /// already sent: done, pointing at the NAS's copy, showing the version the
    /// camera made. An edit made to it later is still sent, as any edit is.
    convenience init(alreadyOnNAS original: DownloadedOriginal, localIdentifier: String) {
        let ext = original.url.pathExtension.lowercased()
        let size = (try? original.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.init(
            localIdentifier: localIdentifier,
            filename: original.url.lastPathComponent,
            byteSize: Int64(size),
            mediaType: original.mediaType.rawValue,
            mime: PhotoLibraryScanner.mimeType(for: ext, uti: ""),
            width: 0,
            height: 0,
            capturedAt: original.capturedAt
        )
        state = .done
        assetID = original.assetID
        sentVersion = localIdentifier
        completedAt = Date()
    }
}

/// The share sheet's Save, for originals from the NAS: "Save Image", "Save
/// Video", "Save 3 Items" — the system's own words, in the system's own place —
/// done through `PhotoLibrarySaver` so nothing saved comes back as a duplicate.
/// The system's Save is taken out of the sheet wherever this is offered.
final class SaveToPhotosActivity: UIActivity {
    static let type = UIActivity.ActivityType("com.michaelromero.FrameStation.saveToPhotos")

    private let originals: [DownloadedOriginal]
    private let onFailure: (String) -> Void

    init(originals: [DownloadedOriginal], onFailure: @escaping (String) -> Void) {
        self.originals = originals
        self.onFailure = onFailure
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }

    override var activityTitle: String? {
        let count = originals.count
        let videos = originals.filter { $0.mediaType == .video }.count
        if count == 1 { return videos == 1 ? "Save Video" : "Save Image" }
        if videos == 0 { return "Save \(count) Images" }
        if videos == count { return "Save \(count) Videos" }
        return "Save \(count) Items"
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        !originals.isEmpty
    }

    override func perform() {
        let originals = originals
        Task { @MainActor in
            do {
                try await PhotoLibrarySaver.save(originals)
                activityDidFinish(true)
            } catch {
                onFailure(error.localizedDescription)
                activityDidFinish(false)
            }
        }
    }
}
#endif
#endif
