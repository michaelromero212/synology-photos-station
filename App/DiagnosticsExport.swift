#if os(iOS)
import SwiftUI

/// Hands the diagnostics log over as a Markdown file.
///
/// The share sheet rather than a copy button, because the destination is a Mac
/// across the room: AirDrop is right there in it, and a file arrives readable
/// instead of as a wall of pasted text. Written to the temporary directory,
/// which the system clears on its own — nothing to tidy up afterwards.
struct DiagnosticsExportButton: View {
    @State private var file: URL?
    @State private var isSharing = false
    @State private var failure: String?

    var body: some View {
        Button {
            do {
                file = try Diagnostics.shared.exportFile()
                isSharing = true
            } catch {
                failure = error.localizedDescription
            }
        } label: {
            Label("Export Playback Logs", systemImage: "square.and.arrow.up.on.square")
        }
        .sheet(isPresented: $isSharing) {
            if let file { ShareSheet(items: [file]) }
        }
        .alert(
            "Couldn't write the log",
            isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }

        Text(
            "A record of playback — what the connection delivered, every stall, "
            + "and what the app did about it. AirDrop it to a Mac to read it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
#endif
