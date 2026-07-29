import Foundation
import Logging
import PostgresKit
import SQLKit

/// Applies `Migrations/SQL/*.sql` in filename order, tracked in `schema_migrations`.
///
/// Two constraints shape this:
///
/// 1. PostgresNIO uses the extended query protocol, which rejects multiple
///    statements in one query. Each file is therefore split into individual
///    statements before execution.
/// 2. A pooled `SQLDatabase` hands out a different connection per query, so
///    `BEGIN`/`COMMIT` would land on unrelated connections. Every migration runs
///    pinned to a single connection so it is genuinely atomic.
struct Migrator {
    let logger: Logger

    struct Migration {
        let name: String
        let body: String
    }

    private struct NameRow: Decodable {
        let name: String
    }

    /// Returns the total number of applied migrations.
    @discardableResult
    func migrate(on sql: any SQLDatabase) async throws -> Int {
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
              name       text PRIMARY KEY,
              applied_at timestamptz NOT NULL DEFAULT now()
            )
            """).run()

        let applied = Set(
            try await sql.raw("SELECT name FROM schema_migrations")
                .all(decoding: NameRow.self)
                .map(\.name)
        )

        let pending = try Self.bundledMigrations().filter { !applied.contains($0.name) }
        guard !pending.isEmpty else {
            logger.info("schema up to date (\(applied.count) migrations)")
            return applied.count
        }

        for migration in pending {
            logger.info("applying migration \(migration.name)")
            try await sql.raw("BEGIN").run()
            do {
                for statement in Self.splitStatements(migration.body) {
                    try await sql.raw("\(unsafeRaw: statement)").run()
                }
                try await sql.raw(
                    "INSERT INTO schema_migrations (name) VALUES (\(bind: migration.name))"
                ).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                logger.critical("migration \(migration.name) failed: \(error)")
                throw error
            }
        }

        return applied.count + pending.count
    }

    // MARK: - Loading

    static func bundledMigrations() throws -> [Migration] {
        guard let root = Bundle.module.url(forResource: "SQL", withExtension: nil) else {
            throw MigrationError.bundleMissing
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sql" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try files.map {
            Migration(name: $0.deletingPathExtension().lastPathComponent,
                      body: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    // MARK: - Statement splitting

    /// Splits on semicolons that sit outside single-quoted strings, line
    /// comments, and dollar-quoted blocks.
    static func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inSingleQuote = false
        var inLineComment = false
        var dollarTag: String?

        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]

            if inLineComment {
                current.append(character)
                if character == "\n" { inLineComment = false }
                index = sql.index(after: index)
                continue
            }

            if let tag = dollarTag {
                current.append(character)
                if character == "$", sql[index...].hasPrefix(tag) {
                    let end = sql.index(index, offsetBy: tag.count)
                    current.append(contentsOf: sql[sql.index(after: index)..<end])
                    index = end
                    dollarTag = nil
                    continue
                }
                index = sql.index(after: index)
                continue
            }

            if inSingleQuote {
                current.append(character)
                if character == "'" { inSingleQuote = false }
                index = sql.index(after: index)
                continue
            }

            switch character {
            case "'":
                inSingleQuote = true
                current.append(character)
            case "-" where sql[index...].hasPrefix("--"):
                inLineComment = true
                current.append(character)
            case "$":
                if let tag = Self.dollarTag(in: sql, at: index) {
                    dollarTag = tag
                    current.append(contentsOf: tag)
                    index = sql.index(index, offsetBy: tag.count)
                    continue
                }
                current.append(character)
            case ";":
                statements.append(current)
                current = ""
            default:
                current.append(character)
            }
            index = sql.index(after: index)
        }
        statements.append(current)

        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isWhitespace) }
            .filter { statement in
                // Drop chunks that are nothing but comments.
                statement.split(separator: "\n").contains {
                    !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
                        && !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }
            }
    }

    /// Matches a `$tag$` opener starting at `index`, returning `"$tag$"`.
    private static func dollarTag(in sql: String, at index: String.Index) -> String? {
        var cursor = sql.index(after: index)
        var tag = "$"
        while cursor < sql.endIndex {
            let character = sql[cursor]
            if character == "$" {
                return tag + "$"
            }
            guard character.isLetter || character.isNumber || character == "_" else {
                return nil
            }
            tag.append(character)
            cursor = sql.index(after: cursor)
        }
        return nil
    }
}

enum MigrationError: Error, CustomStringConvertible {
    case bundleMissing

    var description: String {
        switch self {
        case .bundleMissing:
            return "Migrations/SQL resource directory missing from the bundle. "
                + "In Docker, ensure the *.resources bundle is copied next to the binary."
        }
    }
}
