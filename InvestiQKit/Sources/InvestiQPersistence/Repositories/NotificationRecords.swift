import Foundation
import InvestiQCore

public enum NotificationRecords {
    public static func rules(in db: SQLiteDatabase) throws -> [NotificationRule] {
        try db.query("SELECT * FROM notification_rules WHERE instrument_id IS NULL AND portfolio_id IS NULL").map { row in
            guard let id = UUID(uuidString: try row.string("id")) else { throw SQLiteError.typeMismatch(column: "notification_rules.id") }
            return NotificationRule(id: id, kind: try row.enumValue("kind"), threshold: try row.optionalDecimal("threshold"),
                                    enabled: try row.bool("enabled"), createdAt: try row.instant("created_at"),
                                    lastTriggeredAt: row.optionalInstant("last_triggered_at"))
        }
    }

    public static func save(_ rule: NotificationRule, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO notification_rules (id, kind, instrument_id, portfolio_id, threshold, enabled, created_at, last_triggered_at)
            VALUES (?, ?, NULL, NULL, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET threshold = excluded.threshold, enabled = excluded.enabled,
                last_triggered_at = excluded.last_triggered_at
            """, [.text(rule.id.uuidString), .of(rule.kind), .of(rule.threshold), .of(rule.enabled), .of(rule.createdAt), .of(rule.lastTriggeredAt)])
    }

    public static func wasSent(_ key: String, in db: SQLiteDatabase) throws -> Bool {
        (try db.scalarInt("SELECT COUNT(*) FROM notification_log WHERE dedup_key = ?", [.text(key)]) ?? 0) > 0
    }

    public static func logSent(_ key: String, kind: NotificationKind, at date: Date, in db: SQLiteDatabase) throws {
        try db.run("INSERT OR IGNORE INTO notification_log (dedup_key, kind, sent_at) VALUES (?, ?, ?)", [.text(key), .of(kind), .of(date)])
    }

    public static func purgeLog(before date: Date, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM notification_log WHERE sent_at < ?", [.of(date)])
    }
}

extension RiskRecords {
    public struct LevelSnapshot: Sendable {
        public var computedAt: Date
        public var levels: [String: String]
    }

    /// The two most recent assessments (newest first) as category → level.
    public static func latestLevels(portfolioID: PortfolioID, in db: SQLiteDatabase) throws -> [LevelSnapshot] {
        try db.query("SELECT computed_at, payload FROM risk_assessments WHERE portfolio_id = ? ORDER BY computed_at DESC LIMIT 2",
                     [.of(portfolioID)]).map { row in
            let entries: [[String: String]] = try row.json("payload")
            var levels: [String: String] = [:]
            for entry in entries { if let category = entry["category"], let level = entry["level"] { levels[category] = level } }
            return LevelSnapshot(computedAt: try row.instant("computed_at"), levels: levels)
        }
    }
}
