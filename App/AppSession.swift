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
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var serverURL: String = "http://127.0.0.1:8099"
    var inviteCode: String = ""
    /// Shown in every "Added by" row, so it must be a person, not a device.
    var displayName: String = ""
    /// DSM credentials. Held only long enough to post them; never persisted —
    /// the Keychain stores the returned token instead.
    var dsmUsername: String = ""
    var dsmPassword: String = ""
    var useDSMLogin: Bool = true
    private(set) var phase: Phase = .disconnected

    private(set) var user: UserDTO?
    private(set) var spaces: [SpaceDTO] = []
    private(set) var client: FrameStationClient?

    /// The tab structure asks for these by name rather than digging through
    /// `spaces` at each call site.
    var personalSpace: SpaceDTO? { spaces.first { $0.kind == .personal } }
    var serverHost: String? { URL(string: serverURL)?.host() }
    private(set) var loader: ThumbnailLoader?
    private let credentials = CredentialStore()

    var selectedSpace: SpaceDTO?

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
        if let url = defaults.string(forKey: "FSServerURL") { serverURL = url }
        if let code = defaults.string(forKey: "FSInviteCode") { inviteCode = code }
        displayName = defaults.string(forKey: "FSDisplayName") ?? Self.suggestedName
    }

    var shouldAutoConnect: Bool {
        UserDefaults.standard.bool(forKey: "FSAutoConnect")
    }
    #else
    init() { displayName = Self.suggestedName }
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

    /// Reconnects from stored credentials so a relaunch doesn't need a new
    /// invite. Returns false when there's nothing saved.
    @discardableResult
    func restore() async -> Bool {
        guard let saved = credentials.load() else { return false }
        serverURL = saved.serverURL.absoluteString
        phase = .connecting

        let client = FrameStationClient(configuration: .init(baseURL: saved.serverURL, token: saved.token))
        do {
            let me = try await client.me()
            adopt(client: client, me: me)
            return true
        } catch {
            // A rejected token means the device was removed server-side; drop it
            // rather than retrying a credential that will never work again.
            credentials.clear()
            phase = .disconnected
            return false
        }
    }

    func signOut() {
        credentials.clear()
        client = nil
        loader = nil
        user = nil
        spaces = []
        selectedSpace = nil
        phase = .disconnected
    }

    private func adopt(client: FrameStationClient, me: MeResponse) {
        self.client = client
        self.loader = ThumbnailLoader(client: client)
        self.user = me.user
        // The server is the authority on who you are; a restored session had
        // only whatever name was typed at onboarding, or none at all.
        self.displayName = me.user.displayName
        self.spaces = me.spaces
        self.selectedSpace = me.spaces.first { $0.kind == .personal } ?? me.spaces.first
        self.phase = .connected
    }

    /// Signs in with a DSM account. The password is sent once and then cleared
    /// from memory; only the returned token is kept.
    func signInWithDSM() async {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            phase = .failed("That doesn't look like a valid URL.")
            return
        }
        let username = dsmUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !dsmPassword.isEmpty else {
            phase = .failed("Enter your DSM username and password.")
            return
        }

        phase = .connecting
        let client = FrameStationClient(configuration: .init(baseURL: url))
        do {
            let response = try await client.signInWithDSM(
                DSMLoginRequest(
                    username: username,
                    password: dsmPassword,
                    deviceName: deviceName,
                    platform: currentPlatform
                )
            )
            dsmPassword = ""
            try? credentials.save(.init(serverURL: url, token: response.token))

            self.client = client
            self.loader = ThumbnailLoader(client: client)
            self.user = response.user
            self.spaces = response.spaces
            self.selectedSpace = response.spaces.first { $0.kind == .personal } ?? response.spaces.first
            self.phase = .connected
        } catch {
            dsmPassword = ""
            phase = .failed(error.localizedDescription)
        }
    }

    func connect() async {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            phase = .failed("That doesn't look like a valid URL.")
            return
        }

        phase = .connecting
        let client = FrameStationClient(configuration: .init(baseURL: url))

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
                try? credentials.save(.init(serverURL: url, token: token))
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

    func timelineStore(for space: SpaceDTO) -> TimelineStore? {
        guard let client else { return nil }
        return TimelineStore(client: client, spaceID: space.id)
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
