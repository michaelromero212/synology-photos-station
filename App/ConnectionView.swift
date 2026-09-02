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
                AppMark(size: 88)
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
                    // Appears only after DSM has asked. Two-step is off for
                    // most accounts, and a permanently visible code field reads
                    // as something you've forgotten to fill in.
                    if session.needsTwoFactor {
                        Divider().padding(.leading, 2)
                        field(
                            "Six-digit code", text: $session.dsmOTPCode, kind: .otp
                        )
                    }
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
    private enum FieldKind { case host, username, name, code, otp }

    @ViewBuilder
    private func field(
        _ title: String, text: Binding<String>, kind: FieldKind
    ) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .padding(.vertical, 12)
            #if os(iOS)
            .textInputAutocapitalization(kind == .code ? .characters : (kind == .name ? .words : .never))
            .keyboardType(kind == .host ? .URL : (kind == .otp ? .numberPad : .default))
            // `.oneTimeCode` is what makes iOS offer the code above the
            // keyboard instead of making someone switch apps to read it.
            .textContentType(
                kind == .username ? .username
                    : (kind == .name ? .name : (kind == .otp ? .oneTimeCode : nil))
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
        case .launching, .disconnected, .connected:
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
///
/// Two layouts rather than one, because the iOS one does not survive the trip.
/// A `Form` in a `NavigationStack` is right on a phone, where it fills the
/// screen and the navigation bar carries the title and Done. Presented as a Mac
/// sheet the same code has no size to fill, so it collapses to a cramped box
/// with a navigation bar the platform doesn't draw — the title vanishes and the
/// rows sit in a strip. A Mac sheet has to state its own width, title itself,
/// and put its buttons along the bottom.
struct AdvancedConnectionSheet: View {
    @Bindable var session: AppSession
    let onDone: () -> Void

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Connection Settings")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Form {
                Section {
                    TextField("Port", text: $session.port)
                } footer: {
                    Text(
                        "FrameStation listens on port \(String(AppSession.defaultPort)) "
                        + "by default. This is its own port, not DSM's."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Picker("Sign in with", selection: $session.useDSMLogin) {
                        Text("DSM Account").tag(true)
                        Text("Invite Code").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(
                        "Family members without a DSM account sign in with an "
                        + "invite code instead."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Stated, because a sheet has no parent to inherit a sensible size
        // from and will otherwise shrink to its tightest content.
        .frame(width: 460)
        #else
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
        #endif
    }
}
#endif
