#if os(macOS)
import SwiftUI

/// Upload status, in the toolbar, at a glance.
///
/// The pattern a Mac already teaches: Safari's downloads button, Xcode's
/// activity view — a small control that fills as work proceeds and opens onto
/// the detail when you want it. It earns its place in the toolbar only while
/// there is something to say, and stands down when the batch is done.
///
/// A ring rather than a bar because a bar in a toolbar has to be wide enough to
/// read, and would push the other controls around every time an upload started.
/// A ring is the same size whether it is empty or full.
struct MacUploadStatusButton: View {
    let uploads: MacUploads
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                // The track, so an early upload reads as "barely started"
                // rather than as a missing control.
                Circle()
                    .stroke(.quaternary, lineWidth: 2.5)

                Circle()
                    .trim(from: 0, to: max(0.02, uploads.overallFraction))
                    .stroke(
                        uploads.failed > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    // Twelve o'clock, the way every progress ring starts.
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: uploads.overallFraction)

                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(uploads.failed > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 18, height: 18)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MacUploadQueueView(uploads: uploads)
        }
    }

    /// A tick over a batch that failed would be a lie told quietly.
    private var symbol: String {
        if uploads.pending > 0 { return "arrow.up" }
        return uploads.failed > 0 ? "exclamationmark" : "checkmark"
    }

    private var helpText: String {
        if uploads.pending > 0 {
            return uploads.pending == 1
                ? "Uploading 1 item" : "Uploading \(uploads.pending) items"
        }
        if uploads.failed > 0 {
            return uploads.failed == 1
                ? "1 item failed to upload" : "\(uploads.failed) items failed to upload"
        }
        if uploads.skipped > 0, uploads.completed == 0 {
            return uploads.skipped == 1
                ? "1 item already in your library" : "\(uploads.skipped) items already in your library"
        }
        return uploads.completed == 1
            ? "1 item uploaded" : "\(uploads.completed) items uploaded"
    }
}

/// The queue itself, with a real bar on the item actually moving.
///
/// The rest say "Waiting" rather than each carrying a bar pinned at zero: a
/// column of empty progress bars reads as forty stalled uploads instead of one
/// running and thirty-nine queued.
struct MacUploadQueueView: View {
    let uploads: MacUploads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if uploads.queue.isEmpty, uploads.finished.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Uploading", systemImage: "checkmark.circle")
                } description: {
                    Text("Choose Add Photos, or drop files onto the library.")
                }
                .frame(height: 180)
            } else {
                // What's moving now, above what's already finished — so a
                // duplicate or a failure stays visible instead of the row simply
                // disappearing when it's done.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(uploads.queue.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            MacUploadRow(item: item, isActive: index == 0)
                        }
                        ForEach(Array(uploads.finished.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 || !uploads.queue.isEmpty { Divider() }
                            MacFinishedRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if let error = uploads.lastError, uploads.failed > 0 {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(uploads.pending > 0 ? "Uploading" : "Uploads")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if uploads.pending == 0, uploads.completed > 0 {
                Button("Clear") { uploads.reset() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        var parts: [String] = []
        if uploads.pending > 0 { parts.append("\(uploads.pending) waiting") }
        if uploads.completed > 0 { parts.append("\(uploads.completed) done") }
        if uploads.skipped > 0 { parts.append("\(uploads.skipped) skipped") }
        if uploads.failed > 0 { parts.append("\(uploads.failed) failed") }
        return parts.isEmpty ? "Nothing queued" : parts.joined(separator: " · ")
    }
}

private struct MacUploadRow: View {
    let item: MacUploads.Item
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "arrow.up.circle.fill" : "clock")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isActive {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                        Text("\(bytes(item.sent)) of \(bytes(item.total))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        // Indeterminate while hashing: there is no fraction
                        // yet, and a bar at zero reads as stuck.
                        ProgressView().progressViewStyle(.linear)
                        Text("Preparing…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Waiting")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

/// A file the queue has finished with, and what became of it: uploaded, skipped
/// as a duplicate, or failed. The duplicate line is the "already exists" feedback
/// — a re-drop of photos already in the library reads as such instead of as a
/// silent no-op.
private struct MacFinishedRow: View {
    let entry: MacUploads.Finished

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var glyph: String {
        switch entry.outcome {
        case .uploaded: return "checkmark.circle.fill"
        case .duplicate: return "doc.on.doc.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch entry.outcome {
        case .uploaded: return .green
        case .duplicate: return .secondary
        case .failed: return .orange
        }
    }

    private var label: String {
        switch entry.outcome {
        case .uploaded: return "Uploaded"
        case .duplicate: return "Already in your library — skipped"
        case .failed: return "Failed"
        }
    }
}
#endif
