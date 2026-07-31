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

    /// Asks, then registers. Safe to call repeatedly.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Registers only if the user already said yes — never prompts.
    func registerIfAuthorized() async {
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
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
