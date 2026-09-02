#if os(macOS)
import SwiftUI

/// Preferences, behind ⌘,.
///
/// The same settings the phone shows in its More tab, in the shape a Mac
/// expects: a tabbed panel that sizes itself, not a scrolling list inside the
/// main window. Sign Out lives here too — it is the one thing on this panel
/// that is not a preference, but it is also the one thing people go looking for
/// under this menu, and burying it somewhere more principled would only mean
/// nobody finds it.
struct MacSettingsView: View {
    @Bindable var session: AppSession

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        // Stated rather than inferred: a Settings scene has no parent to size
        // against and will otherwise shrink to its tightest content, which for
        // two short forms is a panel too small to read.
        .frame(width: 480, height: 300)
    }

    private var general: some View {
        Form {
            Section {
                AutoPlayToggle()
            } footer: {
                Text(
                    "When a video ends, continue to the next video from the "
                    + "same day. Turn this off to play only the video you opened."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                AppearancePicker()
            } footer: {
                Text("Dark keeps the interface out of the way of your photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var account: some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: session.displayName)
                if let host = session.serverHost {
                    LabeledContent("Server", value: host)
                }
                LabeledContent("Version", value: Bundle.appVersion)
            }

            Section {
                NavigationLink {
                    CacheManagementView(session: session)
                } label: {
                    Label("Cache Management", systemImage: "internaldrive")
                }
            } header: {
                Text("Offline")
            }

            Section {
                Button("Sign Out", role: .destructive) { session.signOut() }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
