import Foundation

// Timeline wire types. See ARCHITECTURE.md §6 "Timeline manifest".
//
// The scale driver: at ~100k assets the client must be able to compute the
// entire scroll geometry — every section height, every cell frame, a correct
// fast-scrubber — *before loading a single image*. So the bucket list comes
// first and is tiny, and item detail is fetched per bucket on demand.

public enum TimelineZoom: String, Codable, Sendable, CaseIterable {
    case year, month, day
}

/// One section of the grid: a year, a month, or a day.
public struct TimelineBucket: Codable, Sendable, Hashable, Identifiable {
    /// `2026`, `2026-07`, or `2026-07-18` depending on zoom.
    public let key: String
    public let count: Int
    /// Dominant reverse-geocoded location, for the section header
    /// (`Jul 18 · Culpeper, Virginia`). Null until geocoding runs.
    public let place: String?

    public var id: String { key }

    public init(key: String, count: Int, place: String?) {
        self.key = key
        self.count = count
        self.place = place
    }
}

public struct TimelineManifest: Codable, Sendable, Hashable {
    public let spaceID: UUID
    public let zoom: TimelineZoom
    public let total: Int
    /// `change_log` sequence this manifest reflects. Pass it to `/changes` to
    /// pick up everything that happened since, instead of refetching.
    public let cursor: Int64
    public let buckets: [TimelineBucket]

    public init(spaceID: UUID, zoom: TimelineZoom, total: Int, cursor: Int64, buckets: [TimelineBucket]) {
        self.spaceID = spaceID
        self.zoom = zoom
        self.total = total
        self.cursor = cursor
        self.buckets = buckets
    }
}

/// A single grid cell. Deliberately lean — this is multiplied by bucket size.
public struct TimelineItem: Codable, Sendable, Hashable, Identifiable {
    /// `space_assets.id` — the placement. Use for favourites, delete, attribution.
    public let id: UUID
    /// `assets.id` — the file. Use for thumbnail, preview, and original URLs.
    public let assetID: UUID
    public let capturedAt: Date
    /// width / height, already corrected for EXIF and video rotation. The
    /// justified-grid layout is computed from this without loading anything.
    public let aspectRatio: Double
    public let mediaType: MediaType
    public let durationMs: Int?
    /// Base64 ThumbHash. Paints a recognisable blur with zero network.
    public let thumbHash: String?
    public let isFavorite: Bool
    /// Only meaningful in shared spaces; drives the "Added by" row.
    public let uploadedBy: UUID
    /// True once thumbnails exist. While false the client should keep showing
    /// the ThumbHash rather than requesting an image that will 202.
    public let isDerived: Bool

    public init(
        id: UUID, assetID: UUID, capturedAt: Date, aspectRatio: Double,
        mediaType: MediaType, durationMs: Int?, thumbHash: String?,
        isFavorite: Bool, uploadedBy: UUID, isDerived: Bool
    ) {
        self.id = id
        self.assetID = assetID
        self.capturedAt = capturedAt
        self.aspectRatio = aspectRatio
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.thumbHash = thumbHash
        self.isFavorite = isFavorite
        self.uploadedBy = uploadedBy
        self.isDerived = isDerived
    }

    public var thumbHashBytes: [UInt8]? {
        thumbHash.flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) }
    }
}

public struct TimelineBucketPage: Codable, Sendable, Hashable {
    public let key: String
    public let zoom: TimelineZoom
    public let items: [TimelineItem]

    public init(key: String, zoom: TimelineZoom, items: [TimelineItem]) {
        self.key = key
        self.zoom = zoom
        self.items = items
    }
}

// MARK: - Delta sync

public enum ChangeOperation: String, Codable, Sendable {
    case insert, update, delete
}

public struct SpaceChange: Codable, Sendable, Hashable {
    public let seq: Int64
    public let op: ChangeOperation
    /// `space_assets.id`.
    public let entityID: UUID
    /// Present for insert and update; absent for delete.
    public let item: TimelineItem?

    public init(seq: Int64, op: ChangeOperation, entityID: UUID, item: TimelineItem?) {
        self.seq = seq
        self.op = op
        self.entityID = entityID
        self.item = item
    }
}

public struct SpaceChanges: Codable, Sendable, Hashable {
    public let cursor: Int64
    public let hasMore: Bool
    public let changes: [SpaceChange]

    public init(cursor: Int64, hasMore: Bool, changes: [SpaceChange]) {
        self.cursor = cursor
        self.hasMore = hasMore
        self.changes = changes
    }
}

// MARK: - Detail

/// Everything the Information panel shows. See ARCHITECTURE.md §9a.
public struct AssetDetail: Codable, Sendable, Hashable {
    public let id: UUID
    public let assetID: UUID
    public let spaceID: UUID
    public let mediaType: MediaType
    public let mime: String
    public let byteSize: Int64
    public let width: Int?
    public let height: Int?
    public let durationMs: Int?
    public let capturedAt: Date?
    public let capturedTZOffset: Int?
    public let filename: String?

    // Camera card
    public let cameraMake: String?
    public let cameraModel: String?
    public let lens: String?
    public let iso: Int?
    public let aperture: Double?
    public let shutter: String?
    public let focalLength: Double?
    public let exposureBias: Double?
    public let dynamicRange: String?
    public let isRaw: Bool

    // Map card
    public let latitude: Double?
    public let longitude: Double?
    public let placeName: String?

    // Attribution — the row neither Apple Photos nor Synology has.
    public let uploadedBy: UserDTO
    public let uploadedAt: Date
    /// Suppress the "Added by" row in a personal space.
    public let isSharedSpace: Bool

    public let description: String?
    public let rating: Int?
    public let tags: [String]
    public let isFavorite: Bool
    /// False once the item is archived — on the NAS but no longer on the device.
    public let onDevice: Bool

    public init(
        id: UUID, assetID: UUID, spaceID: UUID, mediaType: MediaType, mime: String,
        byteSize: Int64, width: Int?, height: Int?, durationMs: Int?,
        capturedAt: Date?, capturedTZOffset: Int?, filename: String?,
        cameraMake: String?, cameraModel: String?, lens: String?, iso: Int?,
        aperture: Double?, shutter: String?, focalLength: Double?,
        exposureBias: Double?, dynamicRange: String?, isRaw: Bool,
        latitude: Double?, longitude: Double?, placeName: String?,
        uploadedBy: UserDTO, uploadedAt: Date, isSharedSpace: Bool,
        description: String?, rating: Int?, tags: [String],
        isFavorite: Bool, onDevice: Bool
    ) {
        self.id = id
        self.assetID = assetID
        self.spaceID = spaceID
        self.mediaType = mediaType
        self.mime = mime
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.capturedTZOffset = capturedTZOffset
        self.filename = filename
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
        self.exposureBias = exposureBias
        self.dynamicRange = dynamicRange
        self.isRaw = isRaw
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.uploadedBy = uploadedBy
        self.uploadedAt = uploadedAt
        self.isSharedSpace = isSharedSpace
        self.description = description
        self.rating = rating
        self.tags = tags
        self.isFavorite = isFavorite
        self.onDevice = onDevice
    }

    /// `24 MP` for the camera card.
    public var megapixels: Double? {
        guard let width, let height else { return nil }
        return Double(width * height) / 1_000_000
    }
}
