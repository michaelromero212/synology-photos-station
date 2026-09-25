import Foundation

// Editing what a photo *says about itself*: when it was taken, and which way up
// it goes. Both are corrections of a record rather than edits of an image — the
// pixels are never touched, which is why neither of these rewrites the original
// (see ARCHITECTURE.md §3a: the file is canonical, and its bytes are its
// identity — `assets.sha256` is UNIQUE).

/// A quarter turn, in the direction a person would describe it.
///
/// Relative rather than absolute on purpose: "rotate left" is what the button
/// says, and a client that sent an absolute orientation would have to know the
/// current one — which it doesn't after someone else has already rotated it.
public enum MediaRotation: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case upsideDown
}

/// EXIF orientation, and the arithmetic for changing it.
///
/// Lives in the shared package because the server writes these values and the
/// client reasons about the shape they imply. Two implementations of this table
/// would disagree eventually, and the symptom — a handful of photos sideways in
/// the grid — is miserable to trace back to a transposition.
public enum ExifOrientation {
    public static let normal = 1

    /// Orientations 5 through 8 carry a quarter turn, so the stored pixel
    /// dimensions are transposed relative to how the photo is displayed.
    public static func isQuarterTurn(_ orientation: Int?) -> Bool {
        guard let orientation else { return false }
        return (5...8).contains(orientation)
    }

    /// Stored dimensions as they should actually be shown.
    ///
    /// exiftool reports `ImageWidth`/`ImageHeight` straight off the pixel grid
    /// and leaves the rotation in a separate tag, so a portrait iPhone photo
    /// arrives as 4032×3024 with orientation 6. Anything that reasons about
    /// shape — the justified grid above all — has to apply this first or every
    /// portrait photo comes out landscape.
    public static func displaySize(
        width: Int?, height: Int?, orientation: Int?
    ) -> (width: Int?, height: Int?) {
        guard isQuarterTurn(orientation) else { return (width, height) }
        return (height, width)
    }

    /// The dimensions to record for a file: a size already known, turned to
    /// lie the way the file's own pixels do.
    ///
    /// Stored dimensions are the pixel grid, and the orientation says how to
    /// turn it — see `displaySize`. A phone knows the size exactly (PhotoKit's
    /// numbers, RAW included) but reports it upright, while a portrait iPhone
    /// photo keeps its pixels sideways with orientation 6. Recording the
    /// upright numbers beside the file's orientation turned the photo a second
    /// time, and every portrait shot came out landscape.
    ///
    /// So the recorded numbers are kept, and turned when they disagree with
    /// the file about which side is the long one. A square has no long side to
    /// disagree about. When the record is incomplete, the file's own
    /// dimensions stand in.
    public static func fileOrientedSize(
        recorded: (width: Int?, height: Int?),
        file: (width: Int?, height: Int?)
    ) -> (width: Int?, height: Int?) {
        guard let width = recorded.width, let height = recorded.height else {
            return file.width != nil && file.height != nil ? file : recorded
        }
        guard let fileWidth = file.width, let fileHeight = file.height,
              width != height, fileWidth != fileHeight,
              (width > height) != (fileWidth > fileHeight)
        else { return (width, height) }
        return (height, width)
    }

    /// Display aspect ratio, or nil when the dimensions aren't known.
    public static func aspectRatio(
        width: Int?, height: Int?, orientation: Int?
    ) -> Double? {
        let size = displaySize(width: width, height: height, orientation: orientation)
        guard let width = size.width, let height = size.height,
              width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// The orientation that results from turning the *displayed* image.
    ///
    /// The mirrored values (2, 4, 5, 7) are rare but real — they come out of
    /// front cameras and some scanners — and dropping them would silently
    /// un-mirror somebody's photo the first time they straightened it.
    public static func rotated(_ orientation: Int?, by rotation: MediaRotation) -> Int {
        let current = normalize(orientation)
        switch rotation {
        case .right: return clockwise[current] ?? normal
        case .left: return counterClockwise[current] ?? normal
        case .upsideDown: return halfTurn[current] ?? normal
        }
    }

    /// Anything absent or out of range is treated as unrotated, which is what
    /// a missing tag means anyway.
    public static func normalize(_ orientation: Int?) -> Int {
        guard let orientation, (1...8).contains(orientation) else { return normal }
        return orientation
    }

    private static let clockwise: [Int: Int] = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
    private static let counterClockwise: [Int: Int] = [1: 8, 2: 5, 3: 6, 4: 7, 5: 4, 6: 1, 7: 2, 8: 3]
    private static let halfTurn: [Int: Int] = [1: 3, 2: 4, 3: 1, 4: 2, 5: 7, 6: 8, 7: 5, 8: 6]
}

// MARK: - Requests

/// Re-times one or more photos.
///
/// Per-asset absolute timestamps rather than "shift everything by an hour",
/// because the two modes people actually want — set them all to one time, or
/// slide them all by the same amount and keep the gaps — are both pure
/// arithmetic the client already has the data to do. Sending the answers keeps
/// the server from having to reimplement the same two modes, and lets the sheet
/// show exactly what it is about to apply.
public struct EditCaptureTimeRequest: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public let assetID: UUID
        public let capturedAt: Date

        public init(assetID: UUID, capturedAt: Date) {
            self.assetID = assetID
            self.capturedAt = capturedAt
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

public struct RotateMediaRequest: Codable, Sendable {
    public let assetIDs: [UUID]
    public let rotation: MediaRotation

    public init(assetIDs: [UUID], rotation: MediaRotation) {
        self.assetIDs = assetIDs
        self.rotation = rotation
    }
}

/// What actually took, so the sheet can say "12 updated" rather than guessing.
public struct MediaEditResponse: Codable, Sendable {
    public let updated: Int
    /// Assets that moved to a different folder on disk. Reported because it's
    /// the part a NAS owner will go and look at in File Station.
    public let relocated: Int

    public init(updated: Int, relocated: Int = 0) {
        self.updated = updated
        self.relocated = relocated
    }
}

// MARK: - Credit

/// Who a photo should be attributed to, when that isn't who uploaded it.
///
/// A correction, not a rewrite. `space_assets.uploaded_by_user_id` records which
/// account pushed the bytes and stays exactly as it was; this sets an override
/// that display prefers. The two genuinely differ — a phone handed round at a
/// birthday uploads under whoever is signed in, and a shared iPad backs up the
/// whole household under one account. In both cases the upload record is right
/// and the credit is wrong.
public struct SetCreditRequest: Codable, Sendable, Hashable {
    public let assetIDs: [UUID]
    /// The member to credit, or nil to drop the correction and fall back to
    /// whoever actually uploaded it.
    public let creditedTo: UUID?

    public init(assetIDs: [UUID], creditedTo: UUID?) {
        self.assetIDs = assetIDs
        self.creditedTo = creditedTo
    }
}

// MARK: - Sharing into a space

/// Puts photos into a shared space without taking them out of where they are.
///
/// A copy, not a move — and the distinction is the whole design. Sharing a photo
/// with the family should not empty it out of your own library; whether the
/// original stays is a second, separate decision, made later and once you can
/// see the photos arrived. So this leaves the source placement alone, and the
/// app offers the removal afterwards rather than assuming it.
///
/// The file is hard-linked into the shared tree rather than duplicated, so a
/// shared photo costs a directory entry and no additional storage.
public struct ShareAssetsRequest: Codable, Sendable, Hashable {
    public let assetIDs: [UUID]
    public let destinationSpaceID: UUID

    public init(assetIDs: [UUID], destinationSpaceID: UUID) {
        self.assetIDs = assetIDs
        self.destinationSpaceID = destinationSpaceID
    }
}

/// What landed, and under which ids it can be found there.
///
/// `assetIDs` are the ids **in the destination**, which are deliberately not the
/// ids that were sent: copying into a shared space creates that space's own
/// asset row, so the photo you shared and the photo now in Family Shared are two
/// rows pointing at one file. The app needs the destination ids to walk them,
/// and the source ids would send it looking for photos that aren't there.
///
/// `sourceAssetIDs` come back alongside so the app can offer to remove exactly
/// the originals it just shared, and nothing else.
public struct ShareAssetsResponse: Codable, Sendable, Hashable {
    public let shared: Int
    public let assetIDs: [UUID]
    public let sourceAssetIDs: [UUID]
    public let destinationSpaceID: UUID

    public init(
        shared: Int, assetIDs: [UUID], sourceAssetIDs: [UUID], destinationSpaceID: UUID
    ) {
        self.shared = shared
        self.assetIDs = assetIDs
        self.sourceAssetIDs = sourceAssetIDs
        self.destinationSpaceID = destinationSpaceID
    }
}

// MARK: - Location

/// Where a photo was taken, when the file is wrong or silent about it.
///
/// Two cases, both common in a family library. Older scans and imports carry no
/// GPS at all, so they are unfindable by place however well you remember where
/// you were. And a phone occasionally records a location that is simply wrong —
/// a cached fix from the last place it had signal.
///
/// Correcting it is worth more than tidiness here: `place_name` is derived from
/// these coordinates, and place is what search actually looks at.
public struct SetLocationRequest: Codable, Sendable, Hashable {
    /// Nil clears the location entirely, for a photo whose recorded position is
    /// wrong and whose real one nobody knows.
    public let latitude: Double?
    public let longitude: Double?

    public init(latitude: Double?, longitude: Double?) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What the server made of it — chiefly the place name, which is derived rather
/// than supplied, so the client shows the same words search will match on.
public struct SetLocationResponse: Codable, Sendable, Hashable {
    public let latitude: Double?
    public let longitude: Double?
    public let placeName: String?

    public init(latitude: Double?, longitude: Double?, placeName: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
    }
}
