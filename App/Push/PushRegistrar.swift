#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Notification permission and APNs token registration.
///
/// The token is useless on its own — it has to reach the server, and it can
/// change (restore from backup, reinstall). So registration is re-run on every
/// launch rather than once, and the last token sent is remembered so a
/// relaunch that produces the same one doesn't chatter at the server.
@Observable
@MainActor
final class PushRegistrar: NSObject {
    /// Shared because the APNs token arrives at the `UIApplicationDelegate`,
    /// which SwiftUI instantiates for us — the delegate and the views have to
    /// be talking about the same registrar.
    static let shared = PushRegistrar()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    private weak var session: AppSession?
    private var pendingToken: String?

    private static let lastTokenKey = "push.lastRegisteredToken"

    func attach(to session: AppSession) {
        self.session = session
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    private static let askedKey = "push.didAsk"
    /// The one-time question, while it is on screen.
    @ObservationIgnored private var asking: Task<Void, Never>?

    /// Asks the one-time notification question on this install, or waits for
    /// the answer if it is already being asked. Returns at once ever after.
    ///
    /// One entry point for everyone who needs the question out of the way,
    /// because on a first launch two things want the screen: this, and backup
    /// setup. Each is a reasonable question and together they were one sitting
    /// on top of the other — the system's alert over a half-read settings sheet.
    /// Whoever gets here first starts the question; anyone else waits for the
    /// same answer, so the next thing appears only once the alert has gone.
    func askOnce() async {
        if let asking {
            await asking.value
            return
        }
        guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        let task = Task { await requestAuthorization() }
        asking = task
        await task.value
        asking = nil
    }

    /// Asks whether banners are welcome. Safe to call repeatedly.
    ///
    /// Only about what is *shown*: registering for a token is separate and
    /// unconditional — see `registerForPushes`.
    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Gets a token. Never prompts, and does not wait to be allowed to.
    ///
    /// It used to return early unless banners had been permitted, which was the
    /// obvious reading and the wrong one: the same token carries the *silent*
    /// push that wakes a stalled backup, and that needs no permission and shows
    /// nothing. Gating it on notification authorization meant somebody who
    /// declined banners — a perfectly ordinary choice — also silently gave up
    /// having their overnight backup rescued. See `BackupNudger` on the server.
    ///
    /// Registering shows no prompt of its own; what a person agreed or declined
    /// to still governs whether anything is ever *displayed*.
    func registerForPushes() async {
        await refreshAuthorization()
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Token plumbing

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingToken = hex
        Task { await send(hex) }
    }

    func didFailToRegister(_ error: any Error) {
        // Expected on a simulator without a paired push environment; not worth
        // showing the user, but worth not losing either.
        lastError = error.localizedDescription
    }

    /// Called once a session exists, in case the token arrived first — on a cold
    /// launch APNs often answers before sign-in finishes.
    func flushPendingRegistration() async {
        guard let pendingToken else { return }
        await send(pendingToken)
    }

    private func send(_ token: String) async {
        guard let client = session?.client else { return }
        do {
            try await client.registerPushToken(
                RegisterPushTokenRequest(apnsToken: token, environment: Self.environment)
            )
            UserDefaults.standard.set(token, forKey: Self.lastTokenKey)
            pendingToken = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A debug build talks to APNs sandbox; a release build (TestFlight or App
    /// Store) talks to production. Sending a sandbox token to the production
    /// host is rejected with BadDeviceToken, so this has to match the build.
    static var environment: APNSEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

// MARK: - Foreground presentation and taps

extension PushRegistrar: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show it even with the app open — you may be in Personal while someone
        // adds to Family Shared.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[PushPayloadKey.spaceID] as? String,
              let spaceID = UUID(uuidString: raw)
        else { return }
        await open(spaceID)
    }

    private func open(_ spaceID: UUID) async {
        // Tapping "Morgan added 3 photos" should land on that space, not
        // wherever you happened to be last.
        await session?.refreshSpaces()
        if let match = session?.spaces.first(where: { $0.id == spaceID }) {
            session?.selectedSpace = match
        }
    }
}
#endif
