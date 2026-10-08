#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Reads the system photo library and turns it into queue rows.
enum PhotoLibraryScanner {

    // MARK: - Authorisation

    enum Access {
        case authorized
        /// The user granted access to *some* photos. Backup is meaningless in
        /// this mode — we'd silently archive twelve photos and call it done —
        /// so the UI says so plainly rather than pretending.
        case limited
        case denied
        case notDetermined
    }

    static var access: Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func requestAccess() async -> Access {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return access
    }

    // MARK: - Scanning

    struct Candidate {
        let asset: PHAsset
        let filename: String
        let byteSize: Int64
        let mediaType: MediaType
        let mime: String
        let isRaw: Bool
        let subtypes: [MediaSubtype]
        /// When the photo was edited, if the file described is an edit. See
        /// `editedAt(of:)`.
        var editedAt: Date? = nil
        /// A Live Photo's motion half. Nil for anything that isn't one.
        var pairedVideo: PairedVideo? = nil
    }

    /// The file facts for a Live Photo's motion half.
    ///
    /// Read from the same list of files as the photo itself, in `describe`. It
    /// used to be a second read of that list for every Live Photo, made on the
    /// main thread as the photo was queued, and Photos loads a file's details
    /// on demand. That's the "Missing prefetched properties … on the main
    /// queue" warning Photos logs.
    ///
    /// Dimensions and duration are deliberately absent rather than borrowed
    /// from the still: the video is a different size to the photo it belongs to
    /// — commonly 1440×1080 beside a 4032×3024 still — and sending the still's
    /// numbers would write a wrong answer the server's own probe then refuses
    /// to correct, because it only fills what is missing. Subtypes are absent
    /// too: they describe the photograph, and a portrait Live Photo's motion is
    /// not a second portrait.
    struct PairedVideo {
        let filename: String
        let byteSize: Int64
        let mime: String
    }

    /// The fetch the full scan and the change observer both use, so "inserted"
    /// means exactly the assets a scan would pick up — nothing hidden, every
    /// burst frame, from the user's own library and anything synced to it from
    /// a computer.
    ///
    /// Not iCloud Shared Albums. Those are other people's photographs, which
    /// Apple keeps at reduced size (2048 px photos, 720p video), and backing
    /// them up filed them in this person's library as their own. Nor the Hidden
    /// album: the app has no hidden photos, so they'd come back unhidden in the
    /// grid and on the TV. See `isBackedUp` for the paths that fetch by id.
    ///
    /// `includeAllBurstAssets`: PhotoKit defaults this to false, which hands
    /// back the burst's representative and hides the other nine — so a timer
    /// burst arrived as a single photograph. Keeping them all means each frame
    /// is its own photo you can open, compare and choose between, which is the
    /// whole reason for taking a burst; the tile carries a badge so it still
    /// reads as one moment rather than ten near-identical accidents.
    static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }

    /// Whether backup should take this asset: the same line `fetchOptions`
    /// draws, for the paths that fetch by identifier and so get whatever they
    /// name. Photos' change history reports shared-album and hidden assets
    /// along with everything else, and a row queued before this rule existed
    /// can still name one.
    static func isBackedUp(_ asset: PHAsset) -> Bool {
        guard !asset.isHidden else { return false }
        return asset.sourceType.contains(.typeUserLibrary)
            || asset.sourceType.contains(.typeiTunesSynced)
    }

    /// Every photo and video in the library, newest first.
    ///
    /// Each photo in an autorelease pool of its own. This is one pass over the
    /// whole library with nothing in it that pauses, so anything Photos hands
    /// back autoreleased for a photo's files would stay in memory until the
    /// last photo had been read, on a phone with tens of thousands of them.
    /// A precaution, not a measured leak. `FileUpload.hashFile` is where the
    /// same mechanism was measured, holding whole videos in memory until iOS
    /// killed the app.
    static func scan(includeVideos: Bool) -> [Candidate] {
        let fetched = PHAsset.fetchAssets(with: fetchOptions())
        var candidates: [Candidate] = []
        candidates.reserveCapacity(fetched.count)

        fetched.enumerateObjects { asset, _, _ in
            autoreleasepool {
                guard asset.mediaType == .image
                    || (asset.mediaType == .video && includeVideos)
                else { return }
                if let candidate = describe(asset) { candidates.append(candidate) }
            }
        }
        return candidates
    }

    /// One asset's file facts. Shared with the share picker so a photo carries
    /// the same filename, MIME and RAW flag whichever way it reaches the NAS.
    ///
    /// Never on the main thread. Reading an asset's files makes Photos load
    /// their details on demand, and every caller runs this in a background
    /// task for that reason.
    static func describe(_ asset: PHAsset) -> Candidate? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = primaryResource(in: resources, for: asset) else { return nil }
        let filename = Self.filename(of: primary, in: resources)
        let ext = (filename as NSString).pathExtension.lowercased()
        return Candidate(
            asset: asset,
            filename: filename,
            byteSize: byteSize(of: primary),
            mediaType: asset.mediaType == .video ? .video : .photo,
            mime: mimeType(for: ext, uti: primary.uniformTypeIdentifier),
            isRaw: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(ext),
            subtypes: subtypes(of: asset),
            editedAt: isRender(primary) ? editedAt(of: asset) : nil,
            pairedVideo: pairedVideo(in: resources, for: asset)
        )
    }

    /// A Live Photo's motion half, from the list of files `describe` already
    /// has. See `PairedVideo`.
    private static func pairedVideo(
        in resources: [PHAssetResource], for asset: PHAsset
    ) -> PairedVideo? {
        guard let resource = livePhotoResource(in: resources, for: asset) else { return nil }
        let filename = Self.filename(of: resource, in: resources)
        return PairedVideo(
            filename: filename,
            byteSize: byteSize(of: resource),
            mime: mimeType(
                for: (filename as NSString).pathExtension.lowercased(),
                uti: resource.uniformTypeIdentifier
            )
        )
    }

    /// The name a file goes to the NAS under.
    ///
    /// An edited render takes its photo's name — see
    /// `BackupKey.renderFilename` — because PhotoKit's own name for one is the
    /// same for every photo. Anything else keeps the name it has.
    private static func filename(
        of resource: PHAssetResource, in resources: [PHAssetResource]
    ) -> String {
        let source: PHAssetResourceType
        switch resource.type {
        case .fullSizePhoto: source = .photo
        case .fullSizeVideo: source = .video
        case .fullSizePairedVideo: source = .pairedVideo
        default: return name(of: resource)
        }
        guard let original = resources.first(where: { $0.type == source }) else {
            return name(of: resource)
        }
        return BackupKey.renderFilename(
            original: name(of: original),
            renderExtension: (name(of: resource) as NSString).pathExtension
        )
    }

    /// A file's own name, as PhotoKit records it.
    ///
    /// iOS 27 renamed `originalFilename` to `filename`, which can also be
    /// missing, and then the name is made from the file's type. Both branches
    /// stay: the app still runs on iOS 17, while the background upload
    /// extension, which compiles this file too, needs iOS 27.
    private static func name(of resource: PHAssetResource) -> String {
        if #available(iOS 27, *) {
            return resource.filename
                ?? UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
                    .map { "Photo.\($0)" }
                ?? "Photo"
        } else {
            return resource.originalFilename
        }
    }

    /// Whether a file is an edited render rather than something the camera made.
    private static func isRender(_ resource: PHAssetResource) -> Bool {
        [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains(resource.type)
    }

    /// When the photo was last edited, or nil when it shows what the camera made.
    ///
    /// iOS 18's own record of the edit where there is one. Before that, the last
    /// time anything about the photo changed — a favorite as much as a crop —
    /// which only ever errs toward looking again: an edit found twice is sent
    /// twice, and the NAS recognizes the bytes the second time.
    static func editedAt(of asset: PHAsset) -> Date? {
        guard asset.hasAdjustments else { return nil }
        if #available(iOS 18, *), let stamp = asset.adjustmentTimestamp {
            return stamp
        }
        return asset.modificationDate ?? asset.creationDate
    }

    /// The ledger key for the version of a photo a file shows: the photo's own
    /// key when it is what the camera made, the key of the edit when it is an
    /// edited render. See `BackupKey`.
    static func versionKey(of asset: PHAsset, sending resource: PHAssetResource) -> String {
        guard isRender(resource), let stamp = editedAt(of: asset) else {
            return asset.localIdentifier
        }
        return BackupKey.edit(of: asset.localIdentifier, editedAt: stamp)
    }

    /// What the device recorded about this asset at capture.
    ///
    /// The server used to work these out from the file: a screenshot was "a PNG
    /// no camera took", a panorama "twice as wide as it is tall". Both guesses
    /// misfire in both directions, and neither could see a screen recording at
    /// all. PhotoKit has known since the shutter, and this class was already
    /// reading `mediaSubtypes` a few lines below to pair Live Photos.
    ///
    /// `.photoLive` and bursts are deliberately absent: they already travel as
    /// `liveGroupID` and `burstID`, which carry the grouping a flag could not.
    static func subtypes(of asset: PHAsset) -> [MediaSubtype] {
        let subtypes = asset.mediaSubtypes
        var result: [MediaSubtype] = []
        if subtypes.contains(.photoScreenshot) { result.append(.screenshot) }
        if subtypes.contains(.photoPanorama) { result.append(.panorama) }
        if subtypes.contains(.videoScreenRecording) { result.append(.screenRecording) }
        // Apple's own name for slow motion is "high frame rate" — the slowing
        // happens on playback, not in the file.
        if subtypes.contains(.videoHighFrameRate) { result.append(.slomo) }
        if subtypes.contains(.videoTimelapse) { result.append(.timelapse) }
        if subtypes.contains(.photoDepthEffect) { result.append(.portrait) }
        if subtypes.contains(.videoCinematic) { result.append(.cinematic) }
        return result
    }

    /// The resource holding the bytes we actually want to archive.
    ///
    /// Prefers the *edited* render when one exists, because that is what the
    /// user sees in Photos — under the original's name, which `describe` gives
    /// it. RAW pairs report `.alternatePhoto` for the JPEG alongside `.photo`
    /// for the RAW; we take the RAW.
    static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        primaryResource(in: PHAssetResource.assetResources(for: asset), for: asset)
    }

    private static func primaryResource(
        in resources: [PHAssetResource], for asset: PHAsset
    ) -> PHAssetResource? {
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    /// The photo as edited — present only while it is.
    static func editedResource(for asset: PHAsset) -> PHAssetResource? {
        let type: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        return PHAssetResource.assetResources(for: asset).first { $0.type == type }
    }

    /// Every image PhotoKit sends for an asset, in the order it sends them.
    ///
    /// A stream and not a single value, because `.opportunistic` delivery is
    /// inherently two-phase: a small degraded placeholder arrives immediately
    /// and the full-quality image follows. That does not fit a continuation,
    /// which may only be resumed once — and both call sites had independently
    /// written the same wrong thing, resuming on the *first* non-nil image.
    /// That image is by definition the blurry one, and the sharp one arriving a
    /// moment later was discarded, so every thumbnail in the picker and every
    /// upload badge was a permanent placeholder.
    ///
    /// Asking for `.highQualityFormat` would also fix the blur, at the cost of
    /// the thing `.opportunistic` exists for: with Optimize Storage on, cells
    /// would stay empty until each image came down from iCloud. Delivering both
    /// keeps the instant paint and sharpens up a moment later.
    ///
    /// This phone's copy of one photo, by the identifier PhotoKit gave it.
    ///
    /// Nil once it has been deleted from the camera roll, which every caller
    /// has to treat as ordinary rather than as a failure — the library on the
    /// NAS outlives the copy on the device, and that is the point of backing up.
    static func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Shared rather than written twice, which is how one bug became two.
    static func thumbnails(
        for asset: PHAsset,
        targetSize: CGSize,
        using manager: PHImageManager = .default()
    ) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // A thumbnail may only exist in iCloud when Optimize Storage is on.
        options.isNetworkAccessAllowed = true

        return AsyncStream { continuation in
            let request = manager.requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFill, options: options
            ) { image, info in
                if let image { continuation.yield(image) }
                // The un-degraded image is the last one coming. So is a failure
                // or a cancellation, neither of which sets the degraded flag —
                // finishing on it is what stops a caller awaiting for ever.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.finish() }
            }
            // Scrolling a cell away cancels its task, which terminates this
            // stream — at which point the fetch it started is wasted work, and
            // on an iCloud library it is wasted *network*.
            continuation.onTermination = { _ in manager.cancelImageRequest(request) }
        }
    }

    /// The paired video half of a Live Photo, if there is one.
    static func livePhotoResource(for asset: PHAsset) -> PHAssetResource? {
        livePhotoResource(in: PHAssetResource.assetResources(for: asset), for: asset)
    }

    private static func livePhotoResource(
        in resources: [PHAssetResource], for asset: PHAsset
    ) -> PHAssetResource? {
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }
        // Full size first: `.pairedVideo` is the original, `.fullSizePairedVideo`
        // the render that matches an edited still. Taking the wrong one pairs a
        // cropped photo with uncropped motion.
        return resources.first { $0.type == .fullSizePairedVideo }
            ?? resources.first { $0.type == .pairedVideo }
    }

    /// The photo on this phone behind a ledger key. See `BackupKey`.
    ///
    /// Nil for a Live Photo's video half: there is no picture of it to draw,
    /// and it has no tile of its own anyway.
    static func asset(forKey key: String) -> PHAsset? {
        guard BackupKey.kind(key) != .pairedVideo else { return nil }
        return asset(for: BackupKey.photo(key))
    }

    /// `PHAssetResource` exposes size only through a private-ish key. Missing
    /// size is not fatal — the uploader learns the real length when it exports.
    static func byteSize(of resource: PHAssetResource) -> Int64 {
        if let value = resource.value(forKey: "fileSize") as? NSNumber {
            return value.int64Value
        }
        return 0
    }

    static func mimeType(for ext: String, uti: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "dng": return "image/x-adobe-dng"
        case "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2": return "image/x-dcraw"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        default:
            return uti.contains("movie") || uti.contains("video")
                ? "video/quicktime" : "image/jpeg"
        }
    }

    // MARK: - Export

    /// Writes the original bytes to a temporary file.
    ///
    /// Required, not incidental: a background `URLSession` upload task must be
    /// file-backed, so a `PHAsset` cannot be streamed straight to the network.
    /// `isNetworkAccessAllowed` matters just as much — with Optimize iPhone
    /// Storage on, the local copy may be a thumbnail and the original has to
    /// come down from iCloud first.
    static func export(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try? FileManager.default.removeItem(at: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

/// How far through the photo library's own history of changes backup has read.
///
/// Photos records every addition and edit, and hands back just the part after a
/// mark saved earlier (iOS 16). That is how photos taken while the app wasn't
/// running are found when it opens, without reading every photo on the phone —
/// see `BackupEngine.catchUp`. The live observer below covers the time it is
/// running; this covers the time it wasn't.
///
/// The mark is kept in preferences as an archived `PHPersistentChangeToken`,
/// which is all it is: a position in one phone's library, meaningless anywhere
/// else, and safe to lose — without it the next catch-up simply starts from
/// wherever the library is then.
enum LibraryChangeHistory {
    /// What changed after the saved mark.
    struct Changes: Sendable {
        /// Added to the library.
        let inserted: [String]
        /// Changed in place — edits among them, and much else. `enqueueEdits`
        /// sorts out which.
        let updated: [String]
    }

    private static let key = "backup.libraryChangeMark"

    /// Where the library's history stands right now, ready to be saved once
    /// everything before it has been dealt with.
    static func currentMark() -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: PHPhotoLibrary.shared().currentChangeToken,
            requiringSecureCoding: true
        )
    }

    static func save(_ mark: Data) {
        UserDefaults.standard.set(mark, forKey: key)
    }

    /// For a ledger that has been emptied: the mark says what the old one had
    /// seen, which is no longer true of anything.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Everything after the saved mark, or nil when Photos can't say — nothing
    /// saved yet, or a mark so old that its history has been let go.
    ///
    /// Something added and then edited while the app was away is reported as
    /// added only: to backup it is a new photo, whatever happened to it since.
    /// Deletions are ignored, as they are live — see `PhotoLibraryChangeMonitor`.
    static func changesSinceMark() -> Changes? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let mark = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: PHPersistentChangeToken.self, from: data
              )
        else { return nil }
        do {
            var inserted = Set<String>()
            var updated = Set<String>()
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: mark) {
                let details = try change.changeDetails(for: .asset)
                inserted.formUnion(details.insertedLocalIdentifiers)
                updated.formUnion(details.updatedLocalIdentifiers)
            }
            updated.subtract(inserted)
            return Changes(inserted: Array(inserted), updated: Array(updated))
        } catch {
            return nil
        }
    }
}

/// Watches the photo library for new and edited assets so backup discovers them
/// the moment they appear, instead of only on a full rescan.
///
/// PhotoKit delivers `photoLibraryDidChange` on its own serial queue, off the
/// main actor, with an incremental diff against a held fetch result — so a new
/// photo costs one small callback, not a re-enumeration of the whole library.
/// The assets' local identifiers (the only thing that has to cross threads, and
/// `Sendable`) are published on `changes`; the engine consumes them on the main
/// actor. Assets *removed* from the library are deliberately ignored here — a
/// backed-up photo the user later deletes locally is a separate concern from
/// discovery, not something to unqueue.
final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver {
    /// One change's worth of identifiers.
    struct Change: Sendable {
        /// Assets added to the library.
        let inserted: [String]
        /// Assets changed in place — an edit, but just as often a favorite, an
        /// album, or iCloud catching up. The engine works out which.
        let changed: [String]
    }

    let changes: AsyncStream<Change>

    private var fetchResult: PHFetchResult<PHAsset>
    private let continuation: AsyncStream<Change>.Continuation

    init(options: PHFetchOptions) {
        let stream = AsyncStream<Change>.makeStream()
        self.changes = stream.stream
        self.continuation = stream.continuation
        self.fetchResult = PHAsset.fetchAssets(with: options)
        super.init()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Serial and off-main. Mutating `fetchResult` here is safe because
        // PhotoKit never overlaps these calls; only identifiers leave the method.
        guard let details = changeInstance.changeDetails(for: fetchResult) else { return }
        fetchResult = details.fetchResultAfterChanges
        let change = Change(
            inserted: details.insertedObjects.map(\.localIdentifier),
            changed: details.changedObjects.map(\.localIdentifier)
        )
        guard !change.inserted.isEmpty || !change.changed.isEmpty else { return }
        continuation.yield(change)
    }

    /// Ends the `changes` stream so its consumer's `for await` loop finishes.
    func finish() { continuation.finish() }
}
#endif
