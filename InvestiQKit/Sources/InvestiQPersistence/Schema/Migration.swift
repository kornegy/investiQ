import Foundation
import InvestiQCore

/// One forward-only schema step. Released migrations are never edited (docs/DATABASE_SCHEMA.md §4).
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public enum MigrationError: Error, Equatable, Sendable {
    /// The database was written by a newer app version; opening it could lose data.
    case databaseNewerThanApp(databaseVersion: Int, supportedVersion: Int)
    case nonSequentialMigrations
    case foreignKeyViolations([String])
}

public enum Migrator {
    /// Applies all pending migrations, each in its own transaction. Returns the applied versions.
    @discardableResult
    public static func migrate(_ database: SQLiteDatabase, migrations: [Migration], now: Date) throws -> [Int] {
        let ordered = migrations.sorted { $0.version < $1.version }
        guard ordered.enumerated().allSatisfy({ $0.offset + 1 == $0.element.version }) else {
            throw MigrationError.nonSequentialMigrations
        }
        let current = database.userVersion
        let latest = ordered.last?.version ?? 0
        guard current <= latest else {
            throw MigrationError.databaseNewerThanApp(databaseVersion: current, supportedVersion: latest)
        }
        var applied: [Int] = []
        for migration in ordered where migration.version > current {
            try database.transaction {
                try database.execute(
                    "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL);"
                )
                try database.execute(migration.sql)
                try database.run("INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?);",
                                 [.integer(Int64(migration.version)), .text(migration.name), .of(now)])
                try database.setUserVersion(migration.version)
                let violations = try database.query("PRAGMA foreign_key_check;")
                if !violations.isEmpty {
                    throw MigrationError.foreignKeyViolations(violations.map { $0.values.first?.textValue ?? "?" })
                }
            }
            applied.append(migration.version)
        }
        return applied
    }
}
