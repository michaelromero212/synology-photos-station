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
///
/// Then the faces "Is this Emma?" asks about, for everyone named, in the
/// order it asks them. Those were cut only when asked for, and a quick yes
/// or no outran them: each question's circle sat gray until its face came
/// (his screenshot, 2026-11-16, at 28 of 50). They're cut large, as that
/// screen draws them (see `FaceCrop.largeSize`). Last, everyone's large
/// circle, for the top of their own page. A pass with nothing new costs one
/// more query per named person with a question.
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
        var circles = Tally()
        for person in people {
            try Task.checkCancellation()
            guard let cover = covers[person.id] else { continue }
            try await cut(userID: userID, sha256: cover.sha256, ordinal: cover.ordinal, into: &circles)
        }

        // The questions, once everyone's circle is made: the People page
        // shows those first. Large, as "Is this Emma?" draws them.
        var questions = Tally()
        var asked = 0
        for person in people where person.name != nil && person.questions > 0 {
            try Task.checkCancellation()
            let faces = try await PeopleController.suggestedFaces(
                userID: userID, spaceID: space.id, personID: person.id, on: app.sql
            )
            asked += faces.count
            for face in faces {
                try Task.checkCancellation()
                try await cut(
                    userID: userID, sha256: face.sha256, ordinal: face.ordinal,
                    size: FaceCrop.largeSize, into: &questions
                )
            }
        }

        // Then everyone's large circle, for the top of their own page. Until
        // it's made the page shows the small one it has, so this goes last.
        var large = Tally()
        for person in people {
            try Task.checkCancellation()
            guard let cover = covers[person.id] else { continue }
            try await cut(
                userID: userID, sha256: cover.sha256, ordinal: cover.ordinal,
                size: FaceCrop.largeSize, into: &large
            )
        }

        let failed = circles.failed + questions.failed + large.failed
        guard circles.made + questions.made + large.made + failed > 0 else { return }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let missed = failed > 0 ? "; \(failed) couldn't be cut" : ""
        let took = String(format: "%.1f", seconds)
        app.logger.info("""
            people: cut \(circles.made) of \(people.count) face circles, \(large.made) large ones \
            and \(questions.made) of \(asked) question faces in \(took) s\(missed)
            """)
    }

    private struct Tally {
        var made = 0
        var failed = 0
    }

    /// One face, behind everything else for the CPU. One already made costs
    /// a file check.
    private func cut(
        userID: UUID, sha256: String, ordinal: Int, size: Int = FaceCrop.size, into tally: inout Tally
    ) async throws {
        do {
            let crop = try await Shell.$isBackground.withValue(true) {
                try await FaceCrop.crop(app: app, userID: userID, sha256: sha256, ordinal: ordinal, size: size)
            }
            if crop.made { tally.made += 1 }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Tried again on the next pass, and by anyone who asks for it
            // meanwhile, which cuts it then as it always did.
            tally.failed += 1
        }
    }
}
