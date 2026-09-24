#if os(iOS)
import Foundation
import SwiftData

/// Whose backup this phone is keeping, and what happens when that changes.
///
/// Signing out used to leave backup exactly as it was: switched on, pointed at
/// "your personal library", with a ledger of which photos had already gone. The
/// next person to sign in on the phone inherited all three. Their camera roll —
/// or rather, the phone's — started uploading into *their* library without
/// anyone having asked them, and every photo the previous person had already
/// sent was marked done and skipped, so it never reached the new library at all.
///
/// So a sign-out now puts backup back where a fresh install has it: off, with
/// its settings at their defaults, and the setup offered again after the next
/// sign-in — the same screen, asking the same questions.
enum BackupAccount {
    private static let ownerKey = "backup.ledgerOwner"
    private static let offeredKey = "backup.setupOffered"

    /// Whether this sign-in has been shown backup setup yet.
    ///
    /// Offered once, whatever the answer. "Not now" is an answer, and asking
    /// again at every launch would be nagging.
    static var setupOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Everything a sign-out resets on this phone. The engine's own shutdown is
    /// separate — see `BackupEngine.retire`.
    static func signedOut() {
        BackupSettings.reset()
        setupOffered = false
    }

    /// Makes the ledger this account's, emptying it if it was someone else's.
    ///
    /// Emptied only for a *different* person. The ledger is how backup knows a
    /// photo is already on the NAS without reading it again, and for the same
    /// person signing back in it is still exactly right — clearing it would have
    /// the next backup re-read and re-hash every photo on the phone, downloading
    /// the ones iCloud keeps elsewhere, to learn that the NAS already has all of
    /// them. Hours, for a large library, and a count of thousands "left" that
    /// never goes anywhere.
    ///
    /// For somebody else it is worse than useless, so it goes, along with any
    /// share left half-sent to the previous person's albums — resumed under the
    /// new account, those would only fail against albums it cannot see.
    @MainActor
    static func adopt(userID: UUID, container: ModelContainer) {
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: ownerKey)
        // No owner recorded means a ledger from before this existed, built by
        // whoever was signed in — which, without a way to switch accounts until
        // now, is the person signing in. Adopted rather than thrown away.
        if let owner, owner != userID.uuidString {
            let context = ModelContext(container)
            try? context.delete(model: BackupItem.self)
            try? context.delete(model: ManualUpload.self)
            try? context.save()
        }
        defaults.set(userID.uuidString, forKey: ownerKey)
    }
}
#endif
