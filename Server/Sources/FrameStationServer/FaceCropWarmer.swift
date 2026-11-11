import Foundation
import SQLKit
import Vapor

/// Makes each person's circle before anyone scrolls to it.
///
/// A circle is cut from its photo the first time it's asked for, and on the
/// NAS's Celeron that's a second or more each: the photo rendered once or
/// twice, then a handful of vips steps. One at a time that went unnoticed. A
/// screenful at once didn't: when crop version 4 and the clean-headshot
/// covers made every circle new (2026-11-10), scrolling People showed gray
/// circles filling in a few at a time (his screenshot, the same day).
///
/// So after each grouping pass, and the first pass comes right after the
/// server starts, everyone People lists has their circle made, in the order
/// People lists them, one at a time, behind everything else for the CPU. A
/// circle already made costs a file check, so a pass with nothing new costs
/// the two queries that list them.
actor FaceCropWarmer {
    private let app: Application
    /// Libraries waiting for a pass, in the order they asked.
    private var waiting: [UUID] = []
    private var task: Task<Void, Never>?

    init(app: Application) {
        self.app = app
    }

    /// Makes this library's circles soon. A library already waiting isn't
    /// queued twice: its one pass will find whatever is newest.
    func warm(_ userID: UUID) {
        if !waiting.contains(userID) { waiting.append(userID) }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    func stop() {
        task?.cancel()
        task = nil
        waiting.removeAll()
    }

    private func drain() async {
        while !Task.isCancelled, !waiting.isEmpty {
            let userID = waiting.removeFirst()
            do {
                try await warmLibrary(userID)
            } catch is CancellationError {
                break
            } catch {
                app.logger.error("people: face circles stopped: \(String(reflecting: error))")
            }
        }
        task = nil
    }

    private func warmLibrary(_ userID: UUID) async throws {
        struct Space: Decodable { let id: UUID }
        guard let space = try await app.sql.raw("""
            SELECT s.id FROM spaces s
            JOIN space_members m ON m.space_id = s.id AND m.user_id = \(bind: userID)
            WHERE s.kind = 'personal'
            LIMIT 1
            """).first(decoding: Space.self)
        else { return }

        let started = ContinuousClock.now
        // Everyone the grid of People shows, in its order: the People row's
        // faces first, then the rest as the grid reaches them.
        let people = try await PeopleController.summaries(
            userID: userID, spaceID: space.id, limit: PeopleController.listLimit, on: app.sql
        )
        let covers = try await PeopleController.covers(
            of: people.map(\.id), userID: userID, spaceID: space.id, on: app.sql
        )
        var made = 0
        var failed = 0
        for person in people {
            try Task.checkCancellation()
            guard let cover = covers[person.id] else { continue }
            do {
                let crop = try await Shell.$isBackground.withValue(true) {
                    try await FaceCrop.crop(app: app, userID: userID, sha256: cover.sha256, ordinal: cover.ordinal)
                }
                if crop.made { made += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Tried again on the next pass, and by anyone who opens
                // People meanwhile, which cuts it then as it always did.
                failed += 1
            }
        }
        guard made + failed > 0 else { return }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let missed = failed > 0 ? "; \(failed) couldn't be cut" : ""
        app.logger.info("people: cut \(made) of \(people.count) face circles in \(String(format: "%.1f", seconds)) s\(missed)")
    }
}
