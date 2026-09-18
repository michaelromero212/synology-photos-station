#if os(iOS)
import SwiftUI

/// Hands the diagnostics log over as a Markdown file.
///
/// The share sheet rather than a copy button, because the destination is a Mac
/// across the room: AirDrop is right there in it, and a file arrives readable
/// instead of as a wall of pasted text. Written to the temporary directory,
/// which the system clears on its own — nothing to tidy up afterwards.
struct DiagnosticsExportButton: View {
    /// Presented by *identity* rather than by a separate boolean.
    ///
    /// Driving this with `isPresented` alongside a second `@State` for the file
    /// is a race: both are set in the same action, and the sheet could evaluate
    /// its content before the file was visible to it — presenting nothing, which
    /// looked exactly like the button doing nothing at all.
    private struct Report: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    @State private var report: Report?
    @State private var failure: String?

    var body: some View {
        Button {
            do {
                // Flush what the watchers are holding before the file is
                // written, so a log exported the moment something looks wrong
                // carries the tally rather than the last twenty-second one.
                ThumbnailWatch.shared.summarize()
                ThumbnailWatch.shared.noteCoverage(LocalOriginals.shared.coverage)
                report = Report(url: try Diagnostics.shared.exportFile())
            } catch {
                failure = error.localizedDescription
            }
        } label: {
            Label("Export Playback Logs", systemImage: "square.and.arrow.up.on.square")
        }
        .sheet(item: $report) { report in
            ShareSheet(items: [report.url])
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
