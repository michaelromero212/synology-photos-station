import Foundation

/// How long a deleted photograph stays recoverable.
///
/// Shared rather than server-side, because both ends state it: the sweeper
/// purges on it, the API hands out a purge date computed from it, and Recently
/// Deleted tells you the number in words. Three copies of `29` would eventually
/// disagree, and the one that disagreed would be the sentence promising the
/// user something the sweeper had no intention of honouring.
public enum Retention {
    public static let days = 29
}
