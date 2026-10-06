#if os(iOS)
import FrameStationAPI
import SwiftUI

/// Curated albums: the two switches, how far along the library is, and the
/// way to take it all back.
///
/// The settings live on the NAS, so flipping one here flips it on every one of
/// this person's devices. The screen says plainly what leaves the phone,
/// because "AI" on a photo app reads as "uploaded somewhere" until it's told
/// otherwise.
struct CurationSettingsView: View {
    let session: AppSession
    let runner: CurationRunner?

    @State private var settings: CurationSettings?
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Toggle("Curate Albums", isOn: binding(for: \.enabled))
                Toggle("Holiday Albums", isOn: binding(for: \.holidays))
            } footer: {
                Text(
                    "This iPhone looks at your photos to find birthdays, beach days, "
                    + "games and holidays for the Albums page. Only what it recognizes, "
                    + "such as \u{201C}beach\u{201D} or \u{201C}cake,\u{201D} goes to your NAS. "
                    + "Your photos aren't sent anywhere for this, and nothing goes "
                    + "anywhere but your NAS."
                )
            }
            .disabled(settings == nil || isSaving)

            if settings?.enabled == true {
                Section("Your Library") {
                    progressRow
                }
            }

            Section {
                Button("Delete AI Data", role: .destructive) {
                    confirmDelete = true
                }
                .disabled(settings == nil || isSaving)
            } footer: {
                Text(
                    "Removes everything your devices recognized and turns Curate "
                    + "Albums off. Your photos, your albums and any names you gave "
                    + "occasions stay as they are."
                )
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Curated Albums")
        // Pushed from More, under the floating tab bar.
        .floatingTabBarClearance()
        .task { await load() }
        .alert("Delete AI Data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Everything your devices recognized in your photos will be removed, "
                + "and Curate Albums will be turned off."
            )
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        let analyzed = runner?.status?.analyzed ?? 0
        let total = runner?.status?.total ?? 0
        VStack(alignment: .leading, spacing: 6) {
            if total > 0 {
                ProgressView(value: Double(analyzed), total: Double(total))
                Text("\(analyzed.formatted()) of \(total.formatted()) photos analyzed")
                    .font(.subheadline)
            }
            Text(stateLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var stateLine: String {
        switch runner?.state ?? .idle {
        case .analyzing:
            return "Analyzing while FrameStation is open."
        case .waiting(let reason):
            return reason + "."
        case .finished:
            return "Up to date. New photos are analyzed while FrameStation is open."
        case .unsupported:
            return "This device needs iOS 18 or later to analyze photos. "
                + "Albums found by your other devices still appear here."
        case .off, .idle:
            return "Analyzes while FrameStation is open, on Wi-Fi."
        }
    }

    private func binding(for key: WritableKeyPath<Toggles, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.map(Toggles.init)?[keyPath: key] ?? false },
            set: { value in
                guard let current = settings else { return }
                var toggles = Toggles(current)
                toggles[keyPath: key] = value
                Task { await save(toggles) }
            }
        )
    }

    /// The switches as one editable value.
    struct Toggles {
        var enabled: Bool
        var holidays: Bool

        init(_ settings: CurationSettings) {
            enabled = settings.enabled
            holidays = settings.holidays
        }
    }

    private func load() async {
        await runner?.refreshStatus()
        if let status = runner?.status {
            settings = status.settings
        } else if let client = session.client {
            settings = try? await client.curationStatus().settings
        }
        if settings == nil {
            failure = "Your NAS needs updating before curated albums can be turned on."
        }
    }

    private func save(_ toggles: Toggles) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            settings = try await client.updateCurationSettings(
                enabled: toggles.enabled, holidays: toggles.holidays
            )
            failure = nil
            await runner?.refreshStatus()
            if settings?.enabled == true { runner?.start() } else { runner?.stop() }
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func deleteData() async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // Off first, so nothing analyzes what's being deleted.
            runner?.stop()
            settings = try await client.updateCurationSettings(enabled: false)
            try await client.deleteCurationData()
            failure = nil
            await runner?.refreshStatus()
        } catch {
            failure = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}
#endif
