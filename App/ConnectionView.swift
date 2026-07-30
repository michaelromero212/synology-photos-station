import FrameStationAPI
import FrameStationKit
import SwiftUI

/// First-run connection. Replaced by real onboarding (Bonjour discovery,
/// Keychain persistence, LAN/remote race) alongside the backup engine in M5.
struct ConnectionView: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                Text("FrameStation")
                    .font(.largeTitle.weight(.semibold))
                Text("Your family's photo library, on your NAS.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            #if !os(tvOS)
            VStack(spacing: 10) {
                TextField("Server URL", text: $session.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                TextField("Your name", text: $session.displayName)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textContentType(.name)
                    #endif

                TextField("Invite code (first time only)", text: $session.inviteCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }
            .frame(maxWidth: 420)
            #endif

            Button("Connect") {
                Task { await session.connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.phase == .connecting)

            status.frame(minHeight: 60)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .disconnected, .connected:
            EmptyView()
        case .connecting:
            ProgressView()
        case .failed(let reason):
            VStack(spacing: 6) {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
