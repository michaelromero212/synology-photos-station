#if os(iOS)
import FrameStationAPI
import Foundation
import Photos
import UIKit

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
    }

    /// Every photo and video in the library, newest first.
    static func scan(includeVideos: Bool) -> [Candidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        // Every frame of a burst, not just the one iOS puts on the cover.
        //
        // PhotoKit defaults this to false, which hands back the burst's
        // representative and hides the other nine — so a timer burst arrived as
        // a single photograph. Keeping them all means each frame is its own
        // photo you can open, compare and choose between, which is the whole
        // reason for taking a burst; the tile carries a badge so it still reads
        // as one moment rather than ten near-identical accidents.
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]

        let fetched = PHAsset.fetchAssets(with: options)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(fetched.count)

        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || (asset.mediaType == .video && includeVideos) else {
                return
            }
            if let candidate = describe(asset) { candidates.append(candidate) }
        }
        return candidates
    }

    /// One asset's file facts. Shared with the share picker so a photo carries
    /// the same filename, MIME and RAW flag whichever way it reaches the NAS.
    static func describe(_ asset: PHAsset) -> Candidate? {
        guard let primary = primaryResource(for: asset) else { return nil }
        let filename = primary.originalFilename
        let ext = (filename as NSString).pathExtension.lowercased()
        return Candidate(
            asset: asset,
            filename: filename,
            byteSize: byteSize(of: primary),
            mediaType: asset.mediaType == .video ? .video : .photo,
            mime: mimeType(for: ext, uti: primary.uniformTypeIdentifier),
            isRaw: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(ext),
            subtypes: subtypes(of: asset)
        )
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
    /// user sees in Photos — but keeps the original's filename and type. RAW
    /// pairs report `.alternatePhoto` for the JPEG alongside `.photo` for the
    /// RAW; we take the RAW.
    static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    /// The paired video half of a Live Photo, if there is one.
    static func livePhotoResource(for asset: PHAsset) -> PHAssetResource? {
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }
        // Full size first: `.pairedVideo` is the original, `.fullSizePairedVideo`
        // the render that matches an edited still. Taking the wrong one pairs a
        // cropped photo with uncropped motion.
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .fullSizePairedVideo }
            ?? resources.first { $0.type == .pairedVideo }
    }

    // MARK: - Live Photo identity

    /// Marks the queue row holding a Live Photo's video half.
    ///
    /// One `PHAsset`, two resources, and a queue keyed on a unique local
    /// identifier — so the second half needs an id of its own. A PHAsset
    /// identifier is a UUID with a `/Lnn/nnn` suffix, so `#` cannot occur in one
    /// and this cannot collide with a real asset.
    static let pairedVideoSuffix = "#pairedVideo"

    /// The `PHAsset` identifier behind a queue row, with any pairing mark
    /// removed. Fetching by the suffixed id finds nothing.
    static func baseIdentifier(_ identifier: String) -> String {
        guard identifier.hasSuffix(pairedVideoSuffix) else { return identifier }
        return String(identifier.dropLast(pairedVideoSuffix.count))
    }

    static func isPairedVideo(_ identifier: String) -> Bool {
        identifier.hasSuffix(pairedVideoSuffix)
    }

    /// The file facts for a Live Photo's motion half.
    ///
    /// Dimensions and duration are deliberately absent rather than borrowed
    /// from the still: the video is a different size to the photo it belongs to
    /// — commonly 1440×1080 beside a 4032×3024 still — and sending the still's
    /// numbers would write a wrong answer the server's own probe then refuses
    /// to correct, because it only fills what is missing.
    static func pairedVideoCandidate(for asset: PHAsset) -> Candidate? {
        guard let resource = livePhotoResource(for: asset) else { return nil }
        return Candidate(
            asset: asset,
            filename: resource.originalFilename,
            byteSize: byteSize(of: resource),
            mediaType: .video,
            mime: mimeType(
                for: (resource.originalFilename as NSString).pathExtension.lowercased(),
                uti: resource.uniformTypeIdentifier
            ),
            isRaw: false,
            // None, deliberately. The subtypes on a Live Photo describe the
            // photograph — a portrait Live Photo is a portrait — and they
            // belong to the still, which is the half the timeline shows. Copying
            // them here would file the same moment under Portrait twice, once
            // for a video nobody can see.
            subtypes: []
        )
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
#endif
