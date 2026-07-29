import Vapor

// Vapor's standard async bootstrap. `app.execute()` dispatches to whichever
// command was requested — `serve` by default, or `invite` from the CLI.
let app: Application

var environment = try Environment.detect()
try LoggingSystem.bootstrap(from: &environment)
app = try await Application.make(environment)

do {
    try await configure(app)
    try await app.execute()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    throw error
}

try await app.asyncShutdown()
