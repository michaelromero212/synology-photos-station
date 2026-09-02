#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos

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
    /// `resource` names which half of the asset to send. Defaults to the one
    /// holding the photo or video itself; the Live Photo path passes the paired
    /// video instead, which is the same asset and different bytes.
    static func send(
        _ asset: PHAsset,
        descriptor: UploadDescriptor,
        to spaceID: UUID,
        client: FrameStationClient,
        resource: PHAssetResource? = nil,
        isAutomaticBackup: Bool = false,
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

        return try await FileUpload.send(
            file: scratch, descriptor: descriptor, to: spaceID, client: client,
            isAutomaticBackup: isAutomaticBackup, onPhase: onPhase
        )
    }
}
#endif
