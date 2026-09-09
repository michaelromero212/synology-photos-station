import Foundation

/// How many transfers run at once — for backup and manual uploads alike.
///
/// One number so the two can't drift apart again. The backup engine runs a pool
/// of this many lanes; the manual upload paths — a Mac file drop
/// (`MacUploads`) and an iOS share / library-pick (`PendingUploads`) — run the
/// same-size pool rather than sending single-file. Three keeps a fast link busy
/// (while one lane holds a big video the others keep photos moving) without
/// saturating home wifi for everything else in the house. That bound is the one
/// the backup queue settled on; the uploads follow it so all three behave alike.
enum UploadConcurrency {
    static let maxLanes = 3
}
