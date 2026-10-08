// Not built for tvOS, like the uploading it describes. See `FileUpload`.
//
// A file of its own so the background upload extension can build the same
// commit the app does, without the rest of the upload engine.
#if !os(tvOS)
import FrameStationAPI
import Foundation

/// Everything the server needs to record one library asset.
///
/// Built either from a queued `BackupItem`, straight from a `PHAsset` (the
/// share picker), or from a file a Mac user chose — so every path commits
/// identical metadata.
///
/// Most fields are optional on purpose. The server's derivation pass fills what
/// arrives missing with what exiftool reads out of the file itself, and leaves
/// alone what arrives set, so a client that genuinely does not know a photo's
/// dimensions or capture date should send nothing rather than a guess: a guess
/// is permanent, a nil is corrected. That is what lets the Mac send a file
/// without reimplementing EXIF parsing.
struct UploadDescriptor {
    var filename: String
    var mime: String
    var mediaType: MediaType
    /// Nil when the uploader genuinely doesn't know — a Live Photo's motion
    /// half, whose size only the file itself records, or any file the Mac has
    /// not opened.
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var capturedAt: Date?
    var capturedTZOffset: Int?
    var capturedTZOffsetFallback: Int?
    /// The file's creation date, for a source with no authoritative capture
    /// time. The server uses it only when EXIF has none.
    var capturedAtFallback: Date?
    var latitude: Double?
    var longitude: Double?
    var isRaw: Bool = false
    var liveGroupID: UUID?
    var burstID: String?
    var burstPick: Bool = false
    /// What the device says this is — screenshot, panorama, slo-mo. Empty for
    /// anything not read off a `PHAsset`: a Live Photo's motion half, and every
    /// file uploaded from a Mac, which has no PhotoKit to ask. Those fall back
    /// to the server's heuristics — see migration 0020.
    var subtypes: [MediaSubtype] = []
    var sourceLocalID: String?

    func commitRequest(spaceID: UUID) -> CommitUploadRequest {
        CommitUploadRequest(
            spaceID: spaceID,
            mediaType: mediaType,
            mime: mime,
            width: width,
            height: height,
            durationMs: durationMs,
            capturedAt: capturedAt,
            // The same instant to the millisecond, which the date itself loses
            // on the wire — see `CommitUploadRequest.capturedAtMs`.
            // Rounded, not truncated: a photo taken at .120 is stored as a
            // double just short of it, and cutting that off sent .119.
            capturedAtMs: capturedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            capturedTZOffset: capturedTZOffset,
            capturedTZOffsetFallback: capturedTZOffsetFallback,
            capturedAtFallback: capturedAtFallback,
            latitude: latitude,
            longitude: longitude,
            isRaw: isRaw,
            liveGroupID: liveGroupID,
            burstID: burstID,
            burstPick: burstPick,
            mediaSubtypes: subtypes,
            sourceLocalID: sourceLocalID
        )
    }
}

#if os(iOS)
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
#endif
#endif
