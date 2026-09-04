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

extension Array where Element == TimelineBucket {
    /// Which bucket a 0…1 position through the library lands on.
    ///
    /// Weighted by item count rather than by bucket index, because a day with
    /// two hundred photos is a long scroll and a day with two is not. An even
    /// split would make the busy stretches of a library nearly impossible to
    /// land in.
    public func bucket(atFraction fraction: Double) -> TimelineBucket? {
        guard !isEmpty else { return nil }
        let total = reduce(0) { $0 + Swift.max($1.count, 1) }
        let target = Double(total) * Swift.min(Swift.max(fraction, 0), 1)
        var running = 0.0
        for bucket in self {
            running += Double(Swift.max(bucket.count, 1))
            if running >= target { return bucket }
        }
        return last
    }

    /// The same moment in time, named at whatever granularity these buckets use.
    ///
    /// Keys nest as prefixes — `2012-06-14` sits inside `2012-06` sits inside
    /// `2012` — which is what makes a density change survivable: the bucket you
    /// were reading at one zoom has an unambiguous counterpart at the next, and
    /// the grid can be told to put it back under your eyes.
    ///
    /// Zooming out finds the shorter key that contains yours. Zooming in finds
    /// the first longer key inside it — first, not any, because buckets run
    /// newest-first, so that is the most recent day of the month or year you
    /// were looking at, which is the edge you were nearest.
    public func counterpart(of key: String) -> String? {
        if contains(where: { $0.key == key }) { return key }
        if let containing = first(where: { key.hasPrefix($0.key) }) { return containing.key }
        if let contained = first(where: { $0.key.hasPrefix(key) }) { return contained.key }
        return nil
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
    /// Which library this placement lives in. Constant across a timeline, but
    /// an album may draw from several.
    public let spaceID: UUID
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
    /// One frame of a burst. The tile says so, because ten near-identical
    /// photographs in a row otherwise read as a mistake rather than a moment.
    public let isBurst: Bool
    /// A Live Photo: this still has a paired video. The paired video is not a
    /// row of its own — it would sit beside its own still as a three-second
    /// silent clip, which is two tiles for one thing somebody photographed once.
    public let liveVideoAssetID: UUID?
    /// When this becomes unrecoverable. Set only for items in Recently Deleted;
    /// nil everywhere else, because nothing else is on a clock.
    ///
    /// A date rather than a number of days, so the retention window lives in
    /// one place on the server. A client subtracting its own constant would go
    /// on counting down to the old day if that window ever changed.
    public let purgeAt: Date?
    /// Which thumbnail generation the server built for this asset. The client
    /// puts it in the thumbnail URL and its cache key, so when the server
    /// regenerates thumbnails (a new sizing or sharpen) the URL changes and the
    /// device fetches the new one instead of serving the old bytes from its
    /// one-year immutable cache. Optional and read as 0 so a payload without it
    /// still decodes — see the `Bool?` fields on `AssetDetail` for why.
    public let thumbVersion: Int?

    public var isLive: Bool { liveVideoAssetID != nil }
    /// The thumbnail generation, with a missing value read as the baseline.
    public var thumbnailVersion: Int { thumbVersion ?? 0 }

    /// Whole days left, rounded up, floored at zero.
    ///
    /// Up rather than down: something deleted twenty minutes ago has 28 days
    /// and change left, and "28 days" reads as a day already lost. Rounding up
    /// says 29 on the day you delete it, which is the number the app promised.
    public var daysUntilPurge: Int? {
        guard let purgeAt else { return nil }
        let seconds = purgeAt.timeIntervalSinceNow
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }

    public init(
        id: UUID, spaceID: UUID, assetID: UUID, capturedAt: Date, aspectRatio: Double,
        mediaType: MediaType, durationMs: Int?, thumbHash: String?,
        isFavorite: Bool, uploadedBy: UUID, isDerived: Bool,
        isBurst: Bool = false, liveVideoAssetID: UUID? = nil, purgeAt: Date? = nil,
        thumbVersion: Int? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.assetID = assetID
        self.capturedAt = capturedAt
        self.aspectRatio = aspectRatio
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.thumbHash = thumbHash
        self.isFavorite = isFavorite
        self.uploadedBy = uploadedBy
        self.isBurst = isBurst
        self.liveVideoAssetID = liveVideoAssetID
        self.isDerived = isDerived
        self.purgeAt = purgeAt
        self.thumbVersion = thumbVersion
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

// MARK: - Extended metadata

/// One labelled value in the extended-metadata dump — a single row of the
/// Information panel's technical section.
public struct MetadataEntry: Codable, Sendable, Hashable {
    /// A human label, e.g. "Focal Length" or "Handler Vendor ID".
    public let label: String
    /// Already formatted for display by the server, e.g. "24 mm" or "Apple".
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of metadata rows, e.g. "General", "Camera", "Video".
///
/// The server does the grouping, ordering, noise-filtering and value
/// formatting, so the client is a dumb renderer: a column of sections, each a
/// title over its rows. Keeping that on the server means one implementation
/// decides what "well organized and not overwhelming" means, and every platform
/// shows the same thing.
public struct MetadataGroup: Codable, Sendable, Hashable {
    public let title: String
    public let entries: [MetadataEntry]

    public init(title: String, entries: [MetadataEntry]) {
        self.title = title
        self.entries = entries
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
    /// What the device recorded this as — screenshot, panorama, slo-mo, and the
    /// rest. Drives the "Kind" line in the Information panel. Optional so a
    /// build that predates it, or a row with none recorded, still decodes.
    public let mediaSubtypes: [MediaSubtype]?
    /// A Live Photo — this still has a paired video. Optional for the same
    /// reason as `mediaSubtypes`: synthesized `Decodable` throws on a missing
    /// key rather than using a default, so a non-optional field here fails the
    /// whole detail decode against any server that has not shipped it yet —
    /// exactly the "data couldn't be read" the panel showed. The name matches
    /// the server's JSON key so the value actually arrives; read it through
    /// `isLive`, which supplies the false a missing key cannot.
    public let isLive: Bool?
    /// One frame of a burst. Optional for the same reason; read via `isBurst`.
    public let isBurst: Bool?
    /// The full technical dump — every meaningful tag exiftool and ffprobe read
    /// out of the file, grouped and formatted for display. Optional for the
    /// same decode-safety reason as the fields above, and nil until the server
    /// has probed the file (older rows fill in over the metadata backfill).
    /// Read via `groups`, which supplies the empty array a missing key cannot.
    public let extendedMetadata: [MetadataGroup]?

    public var subtypes: [MediaSubtype] { mediaSubtypes ?? [] }
    /// The extended metadata, with a missing value read as "none yet".
    public var groups: [MetadataGroup] { extendedMetadata ?? [] }
    private var live: Bool { isLive ?? false }
    private var burst: Bool { isBurst ?? false }

    /// One human label for what this is, the way Photos names it under a photo.
    ///
    /// A single primary kind, chosen by what a person would call it first: a
    /// Live Photo is a Live Photo before it is anything else, a video's
    /// treatment (slo-mo, time-lapse) beats the bare word "Video", and a
    /// photo's nature (screenshot, panorama, portrait) beats "Photo". Burst and
    /// RAW are the fallbacks that still say more than "Photo".
    public var kind: String {
        if live { return "Live Photo" }
        let subtypes = self.subtypes
        if mediaType == .video {
            if subtypes.contains(.screenRecording) { return "Screen Recording" }
            if subtypes.contains(.slomo) { return "Slo-mo" }
            if subtypes.contains(.timelapse) { return "Time-lapse" }
            if subtypes.contains(.cinematic) { return "Cinematic" }
            return "Video"
        }
        if subtypes.contains(.screenshot) { return "Screenshot" }
        if subtypes.contains(.panorama) { return "Panorama" }
        if subtypes.contains(.portrait) { return "Portrait" }
        if burst { return "Burst" }
        if isRaw { return "RAW" }
        return "Photo"
    }

    /// The SF Symbol that goes with `kind`.
    public var kindSymbol: String {
        if live { return "livephoto" }
        let subtypes = self.subtypes
        if mediaType == .video {
            if subtypes.contains(.screenRecording) { return "record.circle" }
            if subtypes.contains(.slomo) { return "slowmo" }
            if subtypes.contains(.timelapse) { return "timelapse" }
            if subtypes.contains(.cinematic) { return "film" }
            return "video"
        }
        if subtypes.contains(.screenshot) { return "camera.viewfinder" }
        if subtypes.contains(.panorama) { return "pano" }
        if subtypes.contains(.portrait) { return "person.crop.square" }
        if burst { return "square.stack.3d.down.right" }
        if isRaw { return "camera.aperture" }
        return "photo"
    }

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
        isFavorite: Bool, onDevice: Bool,
        mediaSubtypes: [MediaSubtype]? = nil, isLive: Bool? = nil, isBurst: Bool? = nil,
        extendedMetadata: [MetadataGroup]? = nil
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
        self.mediaSubtypes = mediaSubtypes
        self.isLive = isLive
        self.isBurst = isBurst
        self.extendedMetadata = extendedMetadata
    }

    /// `24 MP` for the camera card.
    public var megapixels: Double? {
        guard let width, let height else { return nil }
        return Double(width * height) / 1_000_000
    }
}
