import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Exists only to receive the APNs token: `didRegisterForRemoteNotifications`
/// has no SwiftUI equivalent.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared.didFailToRegister(error) }
    }
}
#endif

@main
struct FrameStationApp: App {
    @State private var session = AppSession()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif
    #if os(iOS)
    /// Durable backup queue. On-disk because the engine must survive being
    /// killed mid-run — see BackupQueue.
    private let backupContainer: ModelContainer = {
        do { return try ModelContainer(for: BackupItem.self) }
        catch { fatalError("Could not open the backup queue: \(error)") }
    }()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
            #if os(iOS)
                .modelContainer(backupContainer)
                .environment(\.backupContainer, backupContainer)
            #endif
            #if os(macOS)
                .frame(minWidth: 640, minHeight: 480)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}

struct RootView: View {
    @Bindable var session: AppSession

    var body: some View {
        if session.phase == .connected, let space = session.selectedSpace {
            NavigationStack {
                TimelineView(session: session, space: space)
            }
            #if os(iOS)
            .task {
                let registrar = PushRegistrar.shared
                registrar.attach(to: session)
                // Ask once. Being told a family member shared photos is the
                // point of a shared space, so this is worth a prompt — but only
                // after sign-in, when the app can explain itself.
                if !UserDefaults.standard.bool(forKey: "push.didAsk") {
                    UserDefaults.standard.set(true, forKey: "push.didAsk")
                    await registrar.requestAuthorization()
                } else {
                    await registrar.registerIfAuthorized()
                }
                await registrar.flushPendingRegistration()
            }
            #endif
        } else {
            ConnectionView(session: session)
                .task {
                    // Stored credentials first — a relaunch shouldn't need a
                    // new invite.
                    if await session.restore() { return }
                    if session.shouldAutoConnect, session.phase == .disconnected {
                        await session.connect()
                    }
                }
        }
    }
}
