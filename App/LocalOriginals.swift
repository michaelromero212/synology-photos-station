#if os(iOS)
import Foundation
import Observation

/// Which photos still on this phone are which assets on the NAS.
///
/// Exists because of the window between committing an upload and the server
/// finishing its thumbnail. In that window the grid has nothing to draw: a
/// freshly committed asset is not `isDerived`, and its ThumbHash — the blurred
/// stand-in every other tile opens with — is produced *by* derivation, so it
/// isn't there either. The tile is gray.
///
/// It is gray while the phone is holding the original picture. That is the
/// whole point of this: for anything uploaded from this device we can draw the
/// photograph immediately out of the local library, at no network cost, and let
/// the server's version replace it whenever it turns up.
///
/// The window is small for one photo and enormous for a backup. Thousands of
/// items land in the derivation queue at once, and a person watching their
/// library fill would otherwise watch it fill with gray squares — which is the
/// moment they are most likely to conclude the app has lost their photographs.
///
/// Only ever a *shortcut*, never a source of truth. Every entry is an
/// optimisation that can be dropped at any time: another device's uploads are
/// not in here, nor are this device's after the photo is deleted from the
/// camera roll, and both cases simply fall back to waiting for the server the
/// way they already did.
@Observable
@MainActor
final class LocalOriginals {
    /// One per app. The grid cell that needs this is built by a lazy stack
    /// thousands of times over and has no sensible way to be handed a
    /// dependency, and the mapping is a fact about the device rather than about
    /// any one screen.
    static let shared = LocalOriginals()

    private var byAsset: [UUID: String] = [:]

    /// Bounded, because this is a cache and not a record.
    ///
    /// A full backup pairs every photo on the phone, and holding tens of
    /// thousands of UUID/string pairs for the life of the process to save a
    /// redraw of tiles nobody is looking at any more is the wrong trade. The
    /// pairs that matter are the recent ones — the ones whose derivations are
    /// still in flight — so when it fills, the oldest half goes.
    private static let limit = 4000

    private var order: [UUID] = []

    func record(assetID: UUID, localIdentifier: String) {
        if byAsset[assetID] == nil { order.append(assetID) }
        byAsset[assetID] = localIdentifier
        guard order.count > Self.limit else { return }
        let drop = order.prefix(order.count - Self.limit / 2)
        for assetID in drop { byAsset.removeValue(forKey: assetID) }
        order.removeFirst(drop.count)
    }

    func localIdentifier(for assetID: UUID) -> String? { byAsset[assetID] }

    /// How many photographs this phone can draw without asking the NAS. Read
    /// when a diagnostics log is exported — a small number here is itself the
    /// answer to "why didn't the local copy help".
    var coverage: Int { byAsset.count }

    /// Seeds from the durable upload queue at launch.
    ///
    /// The queue already stores both halves of the pair and survives being
    /// killed mid-run, so a phone that uploaded a thousand photos and was then
    /// force-quit can still draw them while the NAS catches up.
    func adopt(_ pairs: [(assetID: UUID, localIdentifier: String)]) {
        for pair in pairs { record(assetID: pair.assetID, localIdentifier: pair.localIdentifier) }
    }

    func forget() {
        byAsset.removeAll()
        order.removeAll()
    }
}
#endif
