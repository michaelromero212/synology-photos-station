#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Re-times one photo or a whole selection.
///
/// Synology's version of this asks for a "File Type", then explains in a
/// paragraph that it will retain relative time intervals. The two things people
/// actually want are simpler than that, and this names them: either the clock
/// was wrong by a fixed amount and everything should slide together, or these
/// all happened at one moment. One photo gets no choice at all, because there
/// isn't one to make.
struct DateTimeEditorSheet: View {
    let items: [TimelineItem]
    /// Applies the plan and reports how many took, plus how many files moved.
    let apply: ([EditCaptureTimeRequest.Item]) async -> MediaEditResponse?
    let onFinished: (String?) -> Void

    @State private var mode: CaptureTimeEdit.Mode = .shift
    @State private var target: Date
    @State private var isWorking = false
    @State private var failure: String?

    init(
        items: [TimelineItem],
        apply: @escaping ([EditCaptureTimeRequest.Item]) async -> MediaEditResponse?,
        onFinished: @escaping (String?) -> Void
    ) {
        self.items = items
        self.apply = apply
        self.onFinished = onFinished
        // Opens on the earliest shot's own time, so the common correction —
        // nudging a wrong time zone — starts from the real value rather than
        // from today.
        _target = State(
            initialValue: CaptureTimeEdit.anchor(in: items)?.capturedAt ?? Date()
        )
    }

    private var anchor: TimelineItem? { CaptureTimeEdit.anchor(in: items) }
    private var isBulk: Bool { items.count > 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date & Time", selection: $target,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } header: {
                    Text(isBulk ? "New time for the earliest item" : "New date and time")
                } footer: {
                    if let original = anchor?.capturedAt {
                        Text("Currently \(original.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }

                if isBulk {
                    Section {
                        Picker("Apply", selection: $mode) {
                            Text("Keep the gaps").tag(CaptureTimeEdit.Mode.shift)
                            Text("Same time for all").tag(CaptureTimeEdit.Mode.setAll)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("\(items.count) items")
                    } footer: {
                        Text(mode == .shift
                             ? "Every item moves by the same amount, so the order and spacing between them stay as they were."
                             : "Every item is set to exactly this date and time.")
                    }
                }

                Section {
                    // Says the part that surprises people: this is not only a
                    // label change, the file moves on the NAS.
                    Label(
                        "Files move into the folder for their new month, so File Station matches the app.",
                        systemImage: "folder"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Edit Date & Time")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(nil) }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Apply", action: submit).disabled(items.isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func submit() {
        isWorking = true
        failure = nil
        Task {
            let plan = CaptureTimeEdit.plan(items: items, mode: mode, target: target)
            guard let result = await apply(plan) else {
                isWorking = false
                failure = "Couldn't change the date. Nothing was moved."
                return
            }
            isWorking = false
            onFinished(Self.summary(result))
        }
    }

    /// Reports the relocation separately, because "12 updated" and "12 updated,
    /// 9 moved to a new folder" mean different things to someone who is about
    /// to go and look in File Station.
    static func summary(_ result: MediaEditResponse) -> String {
        let items = "\(result.updated) item\(result.updated == 1 ? "" : "s")"
        guard result.relocated > 0 else { return "\(items) re-dated" }
        return "\(items) re-dated, \(result.relocated) moved"
    }
}
#endif
