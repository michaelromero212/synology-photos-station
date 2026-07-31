#if os(iOS)
import SwiftData
import SwiftUI

/// The backup queue's container, passed down so views can build an engine.
/// `@Environment(\.modelContext)` gives a context, not the container the engine
/// needs to make its own contexts on background work.
private struct BackupContainerKey: EnvironmentKey {
    static let defaultValue: ModelContainer? = nil
}

extension EnvironmentValues {
    var backupContainer: ModelContainer? {
        get { self[BackupContainerKey.self] }
        set { self[BackupContainerKey.self] = newValue }
    }
}
#endif
