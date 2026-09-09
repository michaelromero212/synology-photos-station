#if os(macOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Adding photographs to a library from a Mac.
///
/// The Mac has no photo library to back up and no business pretending to — it
/// gets no automatic backup and no Focused Backup, because both exist to work
/// around a phone being suspended mid-transfer and neither problem exists here.
/// What a Mac has is *files*: a folder of scans, a card from a real camera,
/// something dragged out of Messages. So this is upload only, driven by the two
/// gestures a Mac user already expects — choose files, or drop them on the grid.
///
/// Metadata is deliberately thin. Only the filename, MIME type and whether it
/// is a photo or a video are sent; dimensions, capture date, GPS and camera all
/// arrive at the server inside the file, and the derivation pass reads them out
/// with exiftool and fills what came in empty. Parsing EXIF here to send the
/// same answers would be a second implementation that could only ever disagree
/// with the first — and a wrong guess would stick, because the server only
/// fills blanks and never overwrites.
@Observable
@MainActor
final class MacUploads {

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        var sent: Int64 = 0
        var total: Int64 = 0
        var failure: String?
        /// In flight in one of the pool's lanes, so no other lane claims it.
        var isUploading = false

        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1, Double(sent) / Double(total))
        }
    }

    /// What became of a file the queue has finished with.
    enum Outcome {
        case uploaded
        /// The bytes were already in this user's library, so the transfer was
        /// skipped — the "duplicate detected" case. See `FileUpload.Result`.
        case duplicate
        case failed
    }

    /// One finished file, kept so the popover can show what happened rather than
    /// the row simply vanishing. Newest first, capped so a thousand-file drop
    /// doesn't grow this without bound.
    struct Finished: Identifiable {
        let id: UUID
        let filename: String
        let outcome: Outcome
    }

    private(set) var queue: [Item] = []
    private(set) var isRunning = false
    private(set) var completed = 0
    /// Files skipped because they were already in the library — surfaced so a
    /// re-drop of photos already uploaded reads as "already have these" rather
    /// than as nothing happening.
    private(set) var skipped = 0
    private(set) var finished: [Finished] = []
    private(set) var lastError: String?

    /// What a Mac may sensibly send. Anything else the picker or a drag offers
    /// is refused up front rather than uploaded and rejected later.
    static let acceptedTypes: [UTType] = [.image, .movie]

    var pending: Int { queue.count }

    /// How far through the whole batch, counting the item in flight.
    ///
    /// Whole items plus the fraction of the current one, rather than bytes
    /// across everything: byte-accurate progress would need every file's size
    /// up front, and a drop of four hundred photographs would stat all of them
    /// before the first byte moved. Counting items is honest at the only
    /// resolution that matters here and starts instantly.
    var overallFraction: Double {
        let done = Double(completed)
        let outstanding = Double(queue.count)
        guard done + outstanding > 0 else { return 0 }
        // Sum every in-flight lane's progress; waiting items contribute nothing
        // (their fraction is nil), so this generalises the single-item case to
        // the parallel pool.
        let partial = queue.reduce(0.0) { $0 + ($1.fraction ?? 0) }
        return min(1, (done + partial) / (done + outstanding))
    }

    /// Errors are surfaced but never block the batch, so they are counted
    /// separately rather than left only in `lastError` where a second failure
    /// would erase the first.
    private(set) var failed = 0

    /// Clears a finished run so the toolbar indicator can stand down.
    func reset() {
        guard queue.isEmpty else { return }
        completed = 0
        failed = 0
        skipped = 0
        finished.removeAll()
        lastError = nil
    }

    /// Records the fate of a file the queue has finished with, newest first.
    private func recordFinished(_ item: Item, _ outcome: Outcome) {
        finished.insert(Finished(id: item.id, filename: item.filename, outcome: outcome), at: 0)
        if finished.count > 100 { finished.removeLast(finished.count - 100) }
    }

    /// Adds files and starts working through them.
    ///
    /// Directories are walked one level deep rather than refused: dropping a
    /// folder of photographs is the obvious thing to try, and telling somebody
    /// their folder is not a file is a pedantic way to lose a gesture.
    func add(_ urls: [URL], to spaceID: UUID, client: FrameStationClient) {
        let files = urls.flatMap { Self.expand($0) }
        guard !files.isEmpty else { return }

        queue.append(contentsOf: files.map { Item(url: $0, filename: $0.lastPathComponent) })
        guard !isRunning else { return }
        Task { await run(spaceID: spaceID, client: client) }
    }

    private func run(spaceID: UUID, client: FrameStationClient) async {
        isRunning = true
        defer { isRunning = false }

        // A small pool of lanes rather than one serial pass, matching the backup
        // engine: while one lane holds a big video the others keep photos
        // moving, so a drop's speed no longer depends on the mix. Bounded to
        // `UploadConcurrency.maxLanes`. The `repeat` picks up files dropped while
        // the pool was draining its last items.
        repeat {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<UploadConcurrency.maxLanes {
                    group.addTask { @MainActor [weak self] in
                        await self?.drainLane(spaceID: spaceID, client: client)
                    }
                }
            }
        } while queue.contains { !$0.isUploading }
    }

    /// One upload lane: claim the next waiting file, send it, repeat until there
    /// is nothing left to claim.
    private func drainLane(spaceID: UUID, client: FrameStationClient) async {
        while let item = claimNext() {
            do {
                let result = try await upload(item, to: spaceID, client: client)
                // `deduplicated` is set only on the `.have` fast path, where the
                // file was already in this user's library and nothing was sent —
                // exactly the accidental re-upload to flag as a duplicate.
                if result.deduplicated {
                    skipped += 1
                    recordFinished(item, .duplicate)
                } else {
                    completed += 1
                    recordFinished(item, .uploaded)
                }
            } catch {
                // One unreadable file must not strand the rest of a drop.
                lastError = error.localizedDescription
                failed += 1
                recordFinished(item, .failed)
            }
            finish(item.id)
        }
    }

    /// Marks the next waiting file in-flight and returns it, atomically:
    /// synchronous on the main actor, so two lanes can never claim the same file
    /// — the mark lands before any other lane's claim runs.
    private func claimNext() -> Item? {
        guard let index = queue.firstIndex(where: { !$0.isUploading }) else { return nil }
        queue[index].isUploading = true
        return queue[index]
    }

    /// Drops a finished file from the queue — it lives in `finished` now.
    private func finish(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    @discardableResult
    private func upload(
        _ item: Item, to spaceID: UUID, client: FrameStationClient
    ) async throws -> FileUpload.Result {
        // Sandboxed: a dropped or chosen URL carries permission that has to be
        // opened explicitly, and reading without it fails with a bare
        // "no such file" that looks like the file moved.
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }

        let type = UTType(filenameExtension: item.url.pathExtension.lowercased())
        let isVideo = type?.conforms(to: .movie) ?? false

        // The file's own creation date, as a last-resort capture time. A
        // screenshot has no EXIF date, but this is when it was taken — the same
        // date Finder's Get Info shows. Sent as a *fallback*: the server keeps
        // EXIF's date when a real photo has one, and only uses this when it
        // doesn't. The device's current offset comes along so the date reads in
        // local time rather than UTC.
        let created = (try? item.url.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate
        // A screenshot names itself, and a Mac drag has no PhotoKit to ask, so
        // the name is where the kind comes from. Sending it means the photo
        // reads as "Screenshot" the moment it lands, rather than waiting for the
        // server's filename backfill on its next boot.
        let subtypes: [MediaSubtype] =
            item.filename.lowercased().hasPrefix("screenshot") ? [.screenshot] : []

        let descriptor = UploadDescriptor(
            filename: item.filename,
            mime: type?.preferredMIMEType ?? "application/octet-stream",
            mediaType: isVideo ? .video : .photo,
            capturedTZOffsetFallback: created.map { TimeZone.current.secondsFromGMT(for: $0) },
            capturedAtFallback: created,
            isRaw: Self.rawExtensions.contains(item.url.pathExtension.lowercased()),
            subtypes: subtypes
        )

        let id = item.id
        return try await FileUpload.send(
            file: item.url, descriptor: descriptor, to: spaceID, client: client
        ) { [weak self] phase in
            Task { @MainActor in self?.record(phase, for: id) }
        }
    }

    private func record(_ phase: FileUpload.Phase, for id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if case .sending(let sent, let total) = phase {
            queue[index].sent = sent
            queue[index].total = total
        }
    }

    /// A folder becomes the files inside it; anything else is itself.
    private static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else { return accepts(url) ? [url] : [] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter(accepts)
    }

    private static func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return acceptedTypes.contains { type.conforms(to: $0) }
    }

    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
}
#endif
