#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos
import UIKit

extension UploadDescriptor {
    /// Reads a `PHAsset` directly. The timezone rule is the one documented in
    /// ARCHITECTURE.md §4: never claim to know the photographer's offset, only
    /// offer this device's as a fallback the server may use if the file records
    /// none of its own.
    init(asset: PHAsset, candidate: PhotoLibraryScanner.Candidate) {
        self.init(
            filename: candidate.filename,
            mime: candidate.mime,
            mediaType: candidate.mediaType,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            durationMs: asset.duration > 0 ? Int(asset.duration * 1000) : nil,
            capturedAt: asset.creationDate,
            capturedTZOffset: nil,
            capturedTZOffsetFallback: asset.creationDate.map {
                TimeZone.current.secondsFromGMT(for: $0)
            },
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            isRaw: candidate.isRaw,
            liveGroupID: nil,
            burstID: asset.burstIdentifier,
            burstPick: asset.burstSelectionTypes.contains(.userPick)
                || asset.burstSelectionTypes.contains(.autoPick),
            subtypes: candidate.subtypes,
            sourceLocalID: asset.localIdentifier
        )
    }
}

/// The photo-library end of uploading.
///
/// Everything here is about getting bytes *out of PhotoKit*; the transfer
/// itself lives in `FileUpload`, which the Mac uses too. Automatic backup and
/// the share picker differ only in what triggers them, so both come through
/// here and neither owns a second copy of the resumable upload.
enum AssetUploader {

    typealias Result = FileUpload.Result
    typealias Phase = FileUpload.Phase

    /// Exports, then hands the file to `FileUpload`.
    ///
    /// `resource` names which file of the asset to send. Defaults to the one
    /// holding the photo or video itself; backup also sends a Live Photo's
    /// paired video and a later edit's render — the same asset, different bytes.
    static func send(
        _ asset: PHAsset,
        descriptor: UploadDescriptor,
        to spaceID: UUID,
        client: FrameStationClient,
        resource: PHAssetResource? = nil,
        isAutomaticBackup: Bool = false,
        shouldContinue: (@Sendable () async -> Bool)? = nil,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Result {
        guard let resource = resource ?? PhotoLibraryScanner.primaryResource(for: asset) else {
            throw UploadError.noExportableResource
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        onPhase?(.preparing)
        try await PhotoLibraryScanner.export(resource, to: scratch)

        let result = try await FileUpload.send(
            file: scratch, descriptor: descriptor, to: spaceID, client: client,
            isAutomaticBackup: isAutomaticBackup,
            shouldContinue: shouldContinue, onPhase: onPhase
        )

        // Hand over a thumbnail while we still have the photo in our hands.
        //
        // Drawing it from the camera roll covers *this* device; it does nothing
        // for anyone else in the family, who sees a gray tile until the NAS
        // works through its derivation queue. This is the half that fixes that,
        // and it is nearly free: the pixels are already here, and a 512px JPEG
        // is a rounding error next to the original that just went up.
        if let assetID = result.assetID {
            await sendThumbnail(for: asset, assetID: assetID, client: client)
        }
        return result
    }

    /// Renders a grid-sized thumbnail and its ThumbHash and sends them.
    ///
    /// Deliberately swallows every failure. The upload has already succeeded by
    /// this point — the photograph is safe on the NAS — and this is an
    /// optimisation on top of it. Letting a failed thumbnail throw would turn a
    /// stored photo into a reported error and, worse, into a retry that uploads
    /// the whole file again.
    private static func sendThumbnail(
        for asset: PHAsset, assetID: UUID, client: FrameStationClient
    ) async {
        let pixels = CGFloat(PhotoGridMetrics.thumbnailPixels)
        var rendered: UIImage?
        for await image in PhotoLibraryScanner.thumbnails(
            for: asset, targetSize: CGSize(width: pixels, height: pixels)
        ) {
            rendered = image
        }
        guard let rendered,
              let jpeg = rendered.jpegData(compressionQuality: 0.8),
              jpeg.count <= UploadThumbnailRequest.maxBytes
        else { return }

        let request = UploadThumbnailRequest(
            jpeg: jpeg,
            thumbHash: thumbHash(of: rendered),
            size: PhotoGridMetrics.thumbnailPixels
        )
        // Twice, with a pause. One dropped connection used to cost the picture
        // on everybody else's phone until the NAS derived it — a silent loss of
        // the whole benefit, for a request small enough that retrying it is
        // free. Still swallowed after that: the photograph is safe either way.
        for attempt in 0..<2 {
            do {
                try await client.sendThumbnail(assetID: assetID, request)
                return
            } catch {
                guard attempt == 0, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// The ThumbHash for an image, as bytes.
    ///
    /// ThumbHash encodes a roughly 32-pixel impression of a picture into a
    /// couple of dozen bytes — that is the blurred shape a tile shows before
    /// its thumbnail arrives — so the image is drawn down to that size first
    /// rather than handing a 512px bitmap to an encoder that would only throw
    /// almost all of it away.
    ///
    /// Nil on any failure, which costs a blurred stand-in and nothing else.
    private static func thumbHash(of image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        guard longest > 0 else { return nil }
        let scale = min(32 / longest, 1)
        let width = max(Int((CGFloat(cgImage.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(cgImage.height) * scale).rounded()), 1)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Data(ThumbHash.encode(width: width, height: height, rgba: rgba))
    }
}
#endif
