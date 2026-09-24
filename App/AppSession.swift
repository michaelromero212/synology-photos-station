import FrameStationAPI
import FrameStationKit
import Foundation
import Observation

/// Connection + identity for the running app.
///
/// M3 scaffold: the token lives in memory. Keychain persistence, Bonjour
/// discovery, and the split-horizon LAN/remote race all land with onboarding.
@Observable
@MainActor
final class AppSession {
    enum Phase: Equatable {
        /// Before the stored credential has been read and checked.
        ///
        /// Distinct from `disconnected`, which is a *finding* — we looked, and
        /// nobody is signed in. Starting at `disconnected` made the sign-in
        /// screen the launch screen: a signed-in person saw the form until
        /// `/v1/me` answered, which is a network round trip, not a frame.
        case launching
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// Address, split the way Synology's own app asks for it: a name or IP,
    /// a port, and whether to speak TLS. A single URL field made people guess
    /// at a scheme, and `192.168.1.50` on its own parses as a *path*, not a
    /// host, which failed with nothing useful to say.
    var host: String = ""
    var port: String = String(AppSession.defaultPort)
    var useHTTPS: Bool = true

    /// The port FrameStation listens on. Not DSM's 5000/5001 — this is our own
    /// service, and it lives beside DSM rather than in front of it.
    static let defaultPort = 8443

    /// The three fields as one address, or nil if there's nothing usable yet.
    var composedURL: URL? {
        var name = host.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // Tolerate a pasted URL: people paste what their browser shows them.
        for prefix in ["https://", "http://"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if let slash = name.firstIndex(of: "/") { name = String(name[name.startIndex..<slash]) }
        // A pasted host:port wins over the port field, since it is what the
        // person just typed and they'd have to hunt for the other one.
        var chosenPort = port.trimmingCharacters(in: .whitespaces)
        if let colon = name.lastIndex(of: ":"), !name.contains("[") {
            chosenPort = String(name[name.index(after: colon)...])
            name = String(name[name.startIndex..<colon])
        }
        guard !name.isEmpty else { return nil }
        var text = "\(useHTTPS ? "https" : "http")://\(name)"
        if !chosenPort.isEmpty { text += ":\(chosenPort)" }
        return URL(string: text)
    }

    /// Fills the three fields back in from a URL — a restored credential, or a
    /// launch argument.
    func applyAddress(_ url: URL) {
        useHTTPS = url.scheme?.lowercased() == "https"
        host = url.host() ?? ""
        port = url.port.map(String.init) ?? ""
    }
    /// Set when the Keychain refused the token; the session won't outlive the app.
    var keychainWarning: String?
    var inviteCode: String = ""
    /// Shown in every "Added by" row, so it must be a person, not a device.
    var displayName: String = ""
    /// DSM credentials. Held only long enough to post them; never persisted —
    /// the Keychain stores the returned token instead.
    var dsmUsername: String = ""
    var dsmPassword: String = ""
    /// Six digits, and only asked for once DSM has said it wants them. Showing
    /// this field to everyone would be a question most people can't answer.
    var dsmOTPCode: String = ""
    var needsTwoFactor = false
    var useDSMLogin: Bool = true
    private(set) var phase: Phase = .launching

    private(set) var user: UserDTO?
    private(set) var spaces: [SpaceDTO] = []
    private(set) var client: FrameStationClient?

    /// The tab structure asks for these by name rather than digging through
    /// `spaces` at each call site.
    var personalSpace: SpaceDTO? { spaces.first { $0.kind == .personal } }
    var serverHost: String? { host.isEmpty ? nil : host }
    private(set) var loader: ThumbnailLoader?
    private let credentials = CredentialStore()

    #if os(iOS)
    /// Photos on their way to a space, so the grid can draw them before they
    /// arrive. Lives here because an upload outlives the sheet that started it.
    let pendingUploads = PendingUploads()
    #endif

    var selectedSpace: SpaceDTO?

    /// A `-FSServerURL` supplied at launch, if there was one.
    ///
    /// Only ever written by the DEBUG hook below; nil in a shipping build. Held
    /// rather than merely applied to the address fields, because `restore()`
    /// needs to know that the address it is about to read off the stored
    /// credential has been deliberately overridden.
    private var launchServerURL: URL?

    #if DEBUG
    /// Launch-argument hook so the app can be driven headlessly for screenshots
    /// and UI verification:
    ///
    ///     xcrun simctl launch <udid> com.michaelromero.FrameStation \
    ///       -FSServerURL http://127.0.0.1:8099 -FSInviteCode ABCD-1234 -FSAutoConnect YES
    ///
    /// `simctl` turns `-key value` pairs into UserDefaults. DEBUG only — this
    /// must never be a path in a shipping build.
    init() {
        let defaults = UserDefaults.standard
        // Before anything reads the Keychain.
        clearCredentialsIfReinstalled()
        loadRememberedSignInFields()
        // Launch arguments win: they exist to override whatever the last run
        // left behind.
        if let text = defaults.string(forKey: "FSServerURL"), let url = URL(string: text) {
            launchServerURL = url
            applyAddress(url)
        }
        if let code = defaults.string(forKey: "FSInviteCode") { inviteCode = code }
        displayName = defaults.string(forKey: "FSDisplayName") ?? Self.suggestedName
    }

    var shouldAutoConnect: Bool {
        UserDefaults.standard.bool(forKey: "FSAutoConnect")
    }
    #else
    init() {
        // Before anything reads the Keychain.
        clearCredentialsIfReinstalled()
        loadRememberedSignInFields()
        displayName = Self.suggestedName
    }
    var shouldAutoConnect: Bool { false }
    #endif

    /// A guess, not a default — the user is expected to correct it.
    private static var suggestedName: String {
        #if os(macOS)
        return NSFullUserName()
        #else
        return ""
        #endif
    }

    /// Writes the credential and says so if it doesn't stick.
    ///
    /// Silently discarding this failure is how a signed-in session turns into a
    /// sign-in screen on the next launch with nothing to explain it: the token
    /// only ever lives in the Keychain, so a rejected write means the session
    /// dies with the process.
    private func persist(_ credentials: CredentialStore.Credentials) {
        do {
            try self.credentials.save(credentials)
        } catch {
            keychainWarning = "This device couldn't save your sign-in, so you'll "
                + "have to sign in again next time you open FrameStation."
            #if DEBUG
            print("[FrameStation] keychain save failed: \(error)")
            #endif
        }
    }

    func restore() async -> Bool {
        guard let saved = credentials.load() else {
            // Resolve `launching` explicitly. Returning without setting it
            // would leave a first-run user staring at the splash forever.
            phase = .disconnected
            return false
        }
        // The stored address, unless launch arguments overrode it.
        //
        // `init()` says launch arguments win, and until now this line quietly
        // decided otherwise: it read the address back off the credential and put
        // the app straight back on whichever server it last signed in to. So the
        // documented `-FSServerURL` hook worked on a fresh install and silently
        // did nothing on every run after — which is precisely when you reach for
        // it, moving a test build between a laptop server and the NAS.
        //
        // The token travels with the override rather than being discarded.
        // Moving a dev server to a different port does not invalidate anyone's
        // session, and forcing a fresh invite code for a port change would make
        // the hook useless for the thing it exists to do. If the token really
        // doesn't belong to whatever is answering there, the `me()` below gets a
        // 401 and the existing path clears it.
        let baseURL = launchServerURL ?? saved.serverURL
        applyAddress(baseURL)
        // Deliberately *not* `.connecting`: that phase means "you tapped Sign
        // In and we're working on it", and the sign-in form renders for it. A
        // silent restore has no form to show progress in — it stays on the
        // launch screen until it knows the answer.

        let client = FrameStationClient(
            configuration: .init(baseURL: baseURL, token: saved.token),
            session: InstrumentedSession.shared
        )
        // Launch spends its wait here. Timed because it is visibly slower on
        // cellular than on wi-fi, and a number says where it went.
        Diagnostics.shared.log(.launch, "Restoring saved session")
        let began = Date()
        do {
            let me = try await client.me()
            Diagnostics.shared.log(.launch, String(
                format: "Signed in after %.2fs", Date().timeIntervalSince(began)
            ))
            adopt(client: client, me: me)
            return true
        } catch {
            // Only a refusal destroys the credential. A rejected token means the
            // device was removed server-side and will never work again — but an
            // unreachable server means the NAS is asleep, the phone is on mobile
            // data, or Wi-Fi hasn't come up yet, and none of those are a reason
            // to sign someone out.
            //
            // Clearing on every error is why relaunching the app dumped the user
            // back at the sign-in screen: one failed request at launch and the
            // token was gone for good.
            if case FrameStationClientError.http(let status, _) = error,
               status == 401 || status == 403 {
                credentials.clear()
                SessionSnapshotStore.clear()
                TimelineSnapshotStore.clearAll()
                phase = .disconnected
                return false
            }

            // Unreachable, and we know who this is. Going in with the last
            // known account beats showing a sign-in form to someone who never
            // signed out — the token is valid, the library is cached, and the
            // only thing missing is the network. The connection banner is
            // already saying so at the top of the grid.
            if TransferFailure.classify(error) == .unreachable,
               let remembered = SessionSnapshotStore.load() {
                adopt(client: client, me: remembered)
                return true
            }

            // Keep the credential and say what went wrong, so the next
            // launch — or a tap on Retry — can pick up where this left off.
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// What the sign-in screen may remember between sessions.
    ///
    /// The address someone typed and the account they used — conveniences, not
    /// credentials. Never the password.
    ///
    /// These live in UserDefaults rather than the Keychain *because*
    /// UserDefaults is erased when the app is deleted and the Keychain is not.
    /// Storing a hostname somewhere it would outlive the app would be the
    /// wrong trade in the other direction.
    private enum Remembered {
        static let host = "signin.host"
        static let port = "signin.port"
        static let useHTTPS = "signin.useHTTPS"
        static let username = "signin.dsmUsername"
        static let useDSMLogin = "signin.useDSMLogin"
    }

    /// Called once a sign-in has actually worked, so what gets remembered is
    /// what got someone in — not the last thing they mistyped.
    private func rememberSignInFields() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Remembered.host)
        defaults.set(port, forKey: Remembered.port)
        defaults.set(useHTTPS, forKey: Remembered.useHTTPS)
        defaults.set(useDSMLogin, forKey: Remembered.useDSMLogin)
        defaults.set(
            dsmUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Remembered.username
        )
    }

    fileprivate func loadRememberedSignInFields() {
        let defaults = UserDefaults.standard
        guard let savedHost = defaults.string(forKey: Remembered.host) else { return }
        host = savedHost
        if let savedPort = defaults.string(forKey: Remembered.port) { port = savedPort }
        if defaults.object(forKey: Remembered.useHTTPS) != nil {
            useHTTPS = defaults.bool(forKey: Remembered.useHTTPS)
        }
        if defaults.object(forKey: Remembered.useDSMLogin) != nil {
            useDSMLogin = defaults.bool(forKey: Remembered.useDSMLogin)
        }
        dsmUsername = defaults.string(forKey: Remembered.username) ?? ""
    }

    /// The Keychain outlives the app; everything else doesn't.
    ///
    /// Deleting an iOS app erases its UserDefaults, its container and its
    /// SwiftData store — but Keychain items survive, so a reinstall would find
    /// the previous device token and sign straight back in as whoever last
    /// used the phone. Nobody expects a deleted app to remember them.
    ///
    /// The sentinel is the absence of UserDefaults: if the flag is gone, so is
    /// the container, so the app was deleted and the token goes with it.
    fileprivate func clearCredentialsIfReinstalled() {
        let defaults = UserDefaults.standard
        let key = "install.hasLaunchedBefore"
        guard !defaults.bool(forKey: key) else { return }
        credentials.clear()
        defaults.set(true, forKey: key)
    }

    /// Run at the start of `signOut`, before the connection is dropped.
    ///
    /// For work owned somewhere the session can't see — the backup engine lives
    /// in the view tree — that has to finish talking to the NAS on the way out.
    @ObservationIgnored var willSignOut: (() -> Void)?

    /// Signs out without forgetting who you are.
    ///
    /// The token goes and the password was never stored, but the address and
    /// username stay — signing out of a family photo library is routine, and
    /// retyping a NAS hostname every time is a small punishment for it.
    func signOut() {
        // First, while the connection still exists — whatever is registered
        // here may need it one last time. See `BackupEngine.retire`.
        willSignOut?()
        willSignOut = nil
        #if os(iOS)
        // Backup goes back to how a fresh install has it, and is offered again
        // after the next sign-in. See `BackupAccount`.
        BackupAccount.signedOut()
        #endif
        credentials.clear()
        // The cached timeline is this family's dates and places. It must not
        // outlive the session that fetched it, and it must not be sitting
        // there for whoever signs in next.
        TimelineSnapshotStore.clearAll()
        SessionSnapshotStore.clear()
        if let loader { Task { await loader.clearDiskCache() } }
        dsmPassword = ""
        dsmOTPCode = ""
        needsTwoFactor = false
        client = nil
        loader = nil
        // Each one holds a family's photographs and a client that is about to
        // be invalid.
        timelineStores.removeAll()
        #if os(iOS)
        // Which of this phone's photos are which of that account's assets. Of
        // no use to whoever signs in next, and not theirs to hold.
        LocalOriginals.shared.forget()
        #endif
        user = nil
        spaces = []
        selectedSpace = nil
        phase = .disconnected
    }

    private func adopt(client: FrameStationClient, me: MeResponse) {
        // Tied to the client they were built with, so they go when it does.
        // Today every route out of `.connected` runs through `signOut`, which
        // already clears them — but that is an argument about which paths
        // happen to exist, and the invariant belongs next to the assignment
        // that would break it.
        timelineStores.removeAll()
        self.client = client
        self.loader = ThumbnailLoader(
            client: client, diskLimitBytes: CacheSettings.limit.bytes
        )
        self.user = me.user
        // The server is the authority on who you are; a restored session had
        // only whatever name was typed at onboarding, or none at all.
        self.displayName = me.user.displayName
        self.spaces = me.spaces
        self.selectedSpace = me.spaces.first { $0.kind == .personal } ?? me.spaces.first
        self.phase = .connected
        SessionSnapshotStore.save(me)
        // Covers the invite path and re-confirms on every restore, so the
        // remembered address stays whatever last actually worked.
        rememberSignInFields()
    }

    /// Signs in with a DSM account. The password is sent once and then cleared
    /// from memory; only the returned token is kept.
    func signInWithDSM() async {
        guard let url = composedURL else {
            phase = .failed("Enter the address of your NAS.")
            return
        }
        let username = dsmUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !dsmPassword.isEmpty else {
            phase = .failed("Enter your DSM username and password.")
            return
        }

        phase = .connecting
        let client = FrameStationClient(
            configuration: .init(baseURL: url), session: InstrumentedSession.shared
        )
        do {
            let response = try await client.signInWithDSM(
                DSMLoginRequest(
                    username: username,
                    password: dsmPassword,
                    deviceName: deviceName,
                    platform: currentPlatform,
                    otpCode: dsmOTPCode.isEmpty ? nil : dsmOTPCode
                )
            )
            dsmPassword = ""
            dsmOTPCode = ""
            needsTwoFactor = false
            rememberSignInFields()
            persist(.init(serverURL: url, token: response.token))

            timelineStores.removeAll()  // As in `adopt` — they belong to the old client.
            self.client = client
            self.loader = ThumbnailLoader(client: client)
            self.user = response.user
            self.spaces = response.spaces
            self.selectedSpace = response.spaces.first { $0.kind == .personal } ?? response.spaces.first
            self.phase = .connected
        } catch {
            // DSM asking for a code isn't a failed sign-in, it's an unfinished
            // one — so the password survives and only the code is still needed.
            // Clearing it would make every retry a full re-type.
            let reason = error.localizedDescription
            if reason.localizedCaseInsensitiveContains("two-step") {
                needsTwoFactor = true
            } else {
                dsmPassword = ""
                dsmOTPCode = ""
            }
            phase = .failed(reason)
        }
    }

    func connect() async {
        guard let url = composedURL else {
            phase = .failed("Enter the address of your NAS.")
            return
        }

        phase = .connecting
        let client = FrameStationClient(
            configuration: .init(baseURL: url), session: InstrumentedSession.shared
        )

        do {
            let code = inviteCode.trimmingCharacters(in: .whitespaces).uppercased()
            if !code.isEmpty {
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    phase = .failed("Enter your name — it's what your family sees on photos you share.")
                    return
                }
                _ = try await client.redeemInvite(
                    RedeemInviteRequest(
                        code: code,
                        displayName: name,
                        deviceName: deviceName,
                        platform: currentPlatform
                    )
                )
            }

            let me = try await client.me()
            if let token = await client.currentToken {
                persist(.init(serverURL: url, token: token))
            }
            adopt(client: client, me: me)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Re-reads /me so a newly created space appears in the switcher.
    func refreshSpaces(selecting space: SpaceDTO? = nil) async {
        guard let client else { return }
        do {
            let me = try await client.me()
            spaces = me.spaces
            if let space, let match = me.spaces.first(where: { $0.id == space.id }) {
                selectedSpace = match
            }
        } catch {
            // Leave the existing list alone — a transient failure shouldn't
            // empty the switcher.
        }
    }

    var sharedSpaces: [SpaceDTO] { spaces.filter { $0.kind == .shared } }

    /// One store per space, kept for as long as the session is.
    ///
    /// This used to build a fresh `TimelineStore` on every call, and
    /// `TimelineView` asks on every appearance — which inside a `TabView` means
    /// every single tab switch. So leaving Photos and coming back threw the
    /// whole library away and fetched it again: `items` to zero, every cell
    /// rebuilt, every thumbnail re-requested, the grid visibly reassembling
    /// itself. A log from his phone caught it happening **eight times in three
    /// minutes** of ordinary use, across his personal library and a shared one.
    ///
    /// Keeping them also keeps what the store has learned — which buckets are
    /// loaded, and the zoom the user chose — so returning to a tab returns you
    /// to the library you left rather than to a spinner.
    ///
    /// Cleared on `signOut`, with everything else that must not outlive the
    /// session that fetched it.
    private var timelineStores: [UUID: TimelineStore] = [:]

    func timelineStore(for space: SpaceDTO) -> TimelineStore? {
        guard let client else { return nil }
        if let existing = timelineStores[space.id] { return existing }
        let store = TimelineStore(client: client, spaceID: space.id)
        timelineStores[space.id] = store
        return store
    }

    // MARK: - Device identity

    private var currentPlatform: Platform {
        #if os(tvOS)
        return .tvos
        #elseif os(macOS)
        return .macos
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios
        #endif
    }

    private var deviceName: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

}

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
