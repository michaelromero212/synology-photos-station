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
    }

    /// Every photo and video in the library, newest first.
    static func scan(includeVideos: Bool) -> [Candidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]

        let fetched = PHAsset.fetchAssets(with: options)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(fetched.count)

        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || (asset.mediaType == .video && includeVideos) else {
                return
            }
            guard let primary = primaryResource(for: asset) else { return }

            let filename = primary.originalFilename
            let ext = (filename as NSString).pathExtension.lowercased()
            candidates.append(
                Candidate(
                    asset: asset,
                    filename: filename,
                    byteSize: byteSize(of: primary),
                    mediaType: asset.mediaType == .video ? .video : .photo,
                    mime: mimeType(for: ext, uti: primary.uniformTypeIdentifier),
                    isRaw: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(ext)
                )
            )
        }
        return candidates
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
        return PHAssetResource.assetResources(for: asset)
            .first { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
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
