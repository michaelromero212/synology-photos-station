import Foundation
import PostgresKit
import Vapor

/// Postgres connection pool wiring.
///
/// SQLKit rather than Fluent: the schema is hand-written DDL and the queries
/// that matter later (timeline bucket aggregation, change_log deltas, advisory
/// locks) are ones an ORM obstructs.

private struct PostgresPoolKey: StorageKey {
    typealias Value = EventLoopGroupConnectionPool<PostgresConnectionSource>
}

private struct PostgresLifecycle: LifecycleHandler {
    func shutdown(_ application: Application) {
        application.storage[PostgresPoolKey.self]?.shutdown()
    }
}

extension Application {
    var postgresPool: EventLoopGroupConnectionPool<PostgresConnectionSource> {
        guard let pool = storage[PostgresPoolKey.self] else {
            fatalError("Postgres pool accessed before configure(_:) ran.")
        }
        return pool
    }

    var sql: any SQLDatabase {
        postgresPool.database(logger: logger).sql()
    }

    func configurePostgres(url: String) throws {
        let configuration = try SQLPostgresConfiguration(url: url)
        let pool = EventLoopGroupConnectionPool(
            source: PostgresConnectionSource(sqlConfiguration: configuration),
            maxConnectionsPerEventLoop: 4,
            on: eventLoopGroup
        )
        storage[PostgresPoolKey.self] = pool
        lifecycle.use(PostgresLifecycle())
    }
}

extension Request {
    var sql: any SQLDatabase {
        application.postgresPool.database(logger: logger).sql()
    }

    /// See `Application.withPinnedConnection`.
    func withPinnedConnection<T: Sendable>(
        _ body: @escaping @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        try await application.withPinnedConnection(body)
    }
}

extension Application {
    /// Runs `body` against a single checked-out connection.
    ///
    /// Required for anything using `BEGIN`/`COMMIT` or session state: the pooled
    /// `sql` property hands out a potentially different connection per query, so
    /// a transaction opened on one would never bracket work done on another.
    func withPinnedConnection<T: Sendable>(
        _ body: @escaping @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        try await postgresPool
            .withConnection(logger: logger) { connection in
                connection.eventLoop.makeFutureWithTask {
                    try await body(connection.sql())
                }
            }
            .get()
    }
}
