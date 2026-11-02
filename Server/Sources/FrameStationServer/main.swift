import Foundation
import Vapor

// Vapor's standard async bootstrap. `app.startup()` dispatches to whichever
// command was requested — `serve` by default, or `invite` from the CLI.
let app: Application

var environment = try Environment.detect()
try LoggingSystem.bootstrap(from: &environment)
app = try await Application.make(environment)

// A command that stops on an error says why, once, and exits 1. Rethrown from
// top-level code, the error ended the process as a crash instead: "Fatal error
// … Program crashed" and a backtrace pointing nowhere useful, which on the NAS
// read as the import having crashed when it had only refused to start.
do {
    try await configure(app)
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    exit(1)
}
// `app.execute()` in its two halves, with the background work started between
// them: `startup()` returns once `serve` is listening, or once a command has
// finished, and `running` then waits out the server. A port that can't be
// bound throws out of `startup()` before any of that work has started, so
// nothing is left to race the shutdown below. See `startBackgroundWork(_:)`.
do {
    try await app.startup()
    await startBackgroundWork(app)
    try await app.running?.onStop.get()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    exit(1)
}

try await app.asyncShutdown()
