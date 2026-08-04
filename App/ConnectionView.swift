import FrameStationAPI
import FrameStationKit
import SwiftUI

/// First-run connection. Replaced by real onboarding (Bonjour discovery,
/// Keychain persistence, LAN/remote race) alongside the backup engine in M5.
struct ConnectionView: View {
    @Bindable var session: AppSession
    #if !os(tvOS)
    @State private var showAdvanced = false
    #endif

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
            // One grouped block of rows with hairlines between them, the way
            // Synology's own sign-in reads, rather than a stack of separate
            // bordered boxes.
            VStack(spacing: 0) {
                if session.useDSMLogin {
                    field("Hostname or IP", text: $session.host, kind: .host)
                    Divider().padding(.leading, 2)
                    field("Username", text: $session.dsmUsername, kind: .username)
                    Divider().padding(.leading, 2)
                    secureField("Password", text: $session.dsmPassword)
                } else {
                    field("Hostname or IP", text: $session.host, kind: .host)
                    Divider().padding(.leading, 2)
                    field("Your name", text: $session.displayName, kind: .name)
                    Divider().padding(.leading, 2)
                    field("Invite code", text: $session.inviteCode, kind: .code)
                }
                Divider().padding(.leading, 2)

                Toggle("HTTPS", isOn: $session.useHTTPS)
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: 420)
            #endif

            Button(session.useDSMLogin ? "Sign In" : "Connect") {
                Task {
                    if session.useDSMLogin { await session.signInWithDSM() }
                    else { await session.connect() }
                }
            }
            #if os(tvOS)
            .buttonStyle(.borderedProminent)
            #else
            .buttonStyle(SignInButtonStyle())
            .frame(maxWidth: 420)
            #endif
            .disabled(session.phase == .connecting || session.host.trimmingCharacters(in: .whitespaces).isEmpty)

            status.frame(minHeight: 60)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if !os(tvOS)
        // Port and the invite-code path live behind the gear rather than on
        // the front screen: almost nobody changes the port, and a family
        // member redeeming an invite is the rarer of the two ways in.
        .overlay(alignment: .bottomLeading) {
            Button { showAdvanced = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(24)
        }
        .sheet(isPresented: $showAdvanced) {
            AdvancedConnectionSheet(session: session) { showAdvanced = false }
        }
        #endif
    }

    #if !os(tvOS)
    private enum FieldKind { case host, username, name, code }

    @ViewBuilder
    private func field(
        _ title: String, text: Binding<String>, kind: FieldKind
    ) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .padding(.vertical, 12)
            #if os(iOS)
            .textInputAutocapitalization(kind == .code ? .characters : (kind == .name ? .words : .never))
            .keyboardType(kind == .host ? .URL : .default)
            .textContentType(
                kind == .username ? .username : (kind == .name ? .name : nil)
            )
            #endif
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .padding(.vertical, 12)
            #if os(iOS)
            .textContentType(.password)
            #endif
    }
    #endif

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

#if !os(tvOS)
/// Full-width capsule, matching the Sign In button on Synology's screen.
struct SignInButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Port, and the other way in.
struct AdvancedConnectionSheet: View {
    @Bindable var session: AppSession
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Port") {
                        TextField("Port", text: $session.port)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                } footer: {
                    Text("FrameStation listens on port \(String(AppSession.defaultPort)) by default. This is its own port, not DSM's.")
                }

                Section {
                    Picker("Sign in with", selection: $session.useDSMLogin) {
                        Text("DSM Account").tag(true)
                        Text("Invite Code").tag(false)
                    }
                } footer: {
                    Text("Family members without a DSM account sign in with an invite code instead.")
                }
            }
            .navigationTitle("Connection Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
#endif
