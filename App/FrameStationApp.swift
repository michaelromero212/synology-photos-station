import SwiftUI

@main
struct FrameStationApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
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
