import FrameStationKit
import SwiftUI

/// Where the cache limit lives between launches.
enum CacheSettings {
    private static let key = "cache.limit"

    static var limit: CacheLimit {
        get { CacheLimit.from(rawValue: UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// How much of the phone the library is allowed to occupy, and a way to take
/// it back.
///
/// Worth a screen rather than a silent default for two reasons. An app that
/// asks a family to keep their photos on a NAS should be able to answer "how
/// much space is this using" without anyone digging through iOS Settings. And
/// the cache is what browsing offline actually runs on, so the size is a real
/// trade rather than housekeeping: more room here is more library on the plane.
struct CacheManagementView: View {
    @Bindable var session: AppSession

    @State private var limit = CacheSettings.limit
    @State private var used: Int64 = 0
    @State private var isClearing = false

    var body: some View {
        List {
            Section("Usage") {
                HStack {
                    Text("Used Cache Size")
                    Spacer()
                    Text(CacheLimit.describe(bytes: used))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(CacheLimit.allCases) { option in
                    Button {
                        limit = option
                        CacheSettings.limit = option
                        Task { await apply(option) }
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if option == limit {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                        // Without this the row takes the accent color like a
                        // link. These are choices in a list, not actions, and
                        // the only red on this screen should be Clear Cache.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Cache Size")
            } footer: {
                Text(
                    "A larger cache keeps more of your library visible when "
                    + "you're away from home or the NAS is unreachable."
                )
            }

            Section {
                Button(role: .destructive) {
                    Task { await clear() }
                } label: {
                    HStack {
                        Spacer()
                        if isClearing {
                            ProgressView()
                        } else {
                            Text("Clear Cache")
                        }
                        Spacer()
                    }
                }
                .disabled(isClearing || used == 0)
            } footer: {
                // Saying what survives matters: someone clearing the cache to
                // free space should not be surprised into an app that can no
                // longer open offline.
                Text(
                    "Removes downloaded photos and videos from this device. "
                    + "Your library stays on the NAS, and the timeline you've "
                    + "already loaded still opens without a connection."
                )
            }
        }
        .navigationTitle("Cache Management")
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await measure() }
    }

    private func measure() async {
        guard let loader = session.loader else { return }
        used = await loader.diskCacheSize()
    }

    private func apply(_ option: CacheLimit) async {
        guard let loader = session.loader else { return }
        await loader.setDiskLimit(option.bytes)
        await measure()
    }

    private func clear() async {
        guard let loader = session.loader else { return }
        isClearing = true
        defer { isClearing = false }
        await loader.clearDiskCache()
        await measure()
    }
}
