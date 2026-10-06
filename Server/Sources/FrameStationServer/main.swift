import Foundation
import Vapor

// Vapor's standard async bootstrap. `app.execute()` dispatches to whichever
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
do {
    try await app.execute()
} catch {
    // `execute()` has already logged it.
    try? await app.asyncShutdown()
    exit(1)
}

try await app.asyncShutdown()
