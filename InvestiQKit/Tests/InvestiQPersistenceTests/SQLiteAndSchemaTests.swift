import XCTest
@testable import InvestiQPersistence
import InvestiQCore
import InvestiQTestSupport

final class SQLiteAndSchemaTests: XCTestCase {
    func migratedUserDatabase() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase()
        try Migrator.migrate(db, migrations: UserSchema.migrations, now: fixedNow)
        return db
    }

    func testMigrationIsIdempotentAndRecorded() throws {
        let db = try migratedUserDatabase()
        XCTAssertEqual(db.userVersion, 1)
        XCTAssertEqual(try Migrator.migrate(db, migrations: UserSchema.migrations, now: fixedNow), [])
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_migrations"), 1)
        XCTAssertEqual(try db.integrityCheck(), [])
    }

    func testRefusesDatabaseFromNewerApp() throws {
        let db = try migratedUserDatabase()
        try db.setUserVersion(99)
        XCTAssertThrowsError(try Migrator.migrate(db, migrations: UserSchema.migrations, now: fixedNow)) {
            XCTAssertEqual($0 as? MigrationError, .databaseNewerThanApp(databaseVersion: 99, supportedVersion: 1))
        }
    }

    func testRejectsNonSequentialMigrations() throws {
        let db = try SQLiteDatabase()
        let bad = [Migration(version: 2, name: "x", sql: "SELECT 1;")]
        XCTAssertThrowsError(try Migrator.migrate(db, migrations: bad, now: fixedNow)) {
            XCTAssertEqual($0 as? MigrationError, .nonSequentialMigrations)
        }
    }

    func testFailedMigrationRollsBack() throws {
        let db = try SQLiteDatabase()
        let migrations = [Migration(version: 1, name: "bad", sql: "CREATE TABLE a (x INTEGER); INSERT INTO missing VALUES (1);")]
        XCTAssertThrowsError(try Migrator.migrate(db, migrations: migrations, now: fixedNow))
        XCTAssertEqual(db.userVersion, 0)
        XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name = 'a'").isEmpty)
    }

    func insertPortfolio(_ db: SQLiteDatabase, kind: String = "real") throws -> String {
        let id = UUID().uuidString
        try db.run("INSERT INTO portfolios (id, name, kind, base_currency, created_at) VALUES (?, ?, ?, 'CZK', '2026-01-01T00:00:00Z')",
                   [.text(id), .text("P-\(id.prefix(4))"), .text(kind)])
        return id
    }

    func testTransactionCheckConstraints() throws {
        let db = try migratedUserDatabase()
        let portfolio = try insertPortfolio(db)
        // A buy without instrument/quantity/price violates the CHECK constraint.
        XCTAssertThrowsError(try db.run("""
            INSERT INTO transactions (id, portfolio_id, type, trade_date, currency, source, created_at)
            VALUES ('t1', ?, 'buy', '2026-01-02', 'USD', 'manual', '2026-01-02T00:00:00Z')
            """, [.text(portfolio)])) { error in
            guard case .constraintViolation = error as? SQLiteError else { return XCTFail("\(error)") }
        }
        // Unknown transaction type is rejected.
        XCTAssertThrowsError(try db.run("""
            INSERT INTO transactions (id, portfolio_id, type, trade_date, currency, amount, source, created_at)
            VALUES ('t2', ?, 'leverage', '2026-01-02', 'USD', '1', 'manual', '2026-01-02T00:00:00Z')
            """, [.text(portfolio)]))
        // A valid deposit is accepted.
        XCTAssertNoThrow(try db.run("""
            INSERT INTO transactions (id, portfolio_id, type, trade_date, currency, amount, source, created_at)
            VALUES ('t3', ?, 'deposit', '2026-01-02', 'CZK', '1000', 'manual', '2026-01-02T00:00:00Z')
            """, [.text(portfolio)]))
    }

    func testSimulatorTransactionsOnlyInVirtualPortfolios() throws {
        let db = try migratedUserDatabase()
        let real = try insertPortfolio(db, kind: "real")
        let virtual = try insertPortfolio(db, kind: "virtual")
        let sql = """
            INSERT INTO transactions (id, portfolio_id, type, trade_date, currency, amount, source, created_at)
            VALUES (?, ?, 'deposit', '2026-01-02', 'CZK', '1000', 'simulator', '2026-01-02T00:00:00Z')
            """
        XCTAssertThrowsError(try db.run(sql, [.text("s1"), .text(real)]))
        XCTAssertNoThrow(try db.run(sql, [.text("s2"), .text(virtual)]))
    }

    func testForecastLedgerIsAppendOnly() throws {
        let db = try migratedUserDatabase()
        try db.run("INSERT INTO instruments (id, kind, name, currency, source, created_at, updated_at) VALUES ('i1','stock','Test','USD','manual','x','x')")
        let insert = """
            INSERT INTO forecasts (id, instrument_id, listing_key, model_id, model_version, created_at, origin_date, target_date,
              horizon_days, last_observation_date, origin_value, point, lower80, upper80, lower95, upper95, input_hash, data_source)
            VALUES ('f1','i1','?:TEST','FC-DRIFT','1','2026-01-02T00:00:00Z','2026-01-02','2026-02-02',21,'2026-01-02',100,101,95,107,90,112,'h','demo')
            """
        try db.run(insert)
        XCTAssertThrowsError(try db.run("UPDATE forecasts SET point = 150 WHERE id = 'f1'"))
        XCTAssertThrowsError(try db.run("DELETE FROM forecasts WHERE id = 'f1'"))
        // Look-ahead guard: last observation after origin is rejected.
        XCTAssertThrowsError(try db.run(insert.replacingOccurrences(of: "'f1'", with: "'f2'")
            .replacingOccurrences(of: "21,'2026-01-02'", with: "21,'2026-01-05'")))
    }

    func testForeignKeysAreEnforced() throws {
        let db = try migratedUserDatabase()
        XCTAssertThrowsError(try db.run("INSERT INTO watchlist_items (watchlist_id, instrument_id, added_at) VALUES ('nope','nope','x')"))
    }

    func testSerializeDeserializeRoundTrip() throws {
        let db = try migratedUserDatabase()
        _ = try insertPortfolio(db)
        let image = try db.serialize()
        let restored = try SQLiteDatabase(image: image)
        XCTAssertEqual(restored.userVersion, 1)
        XCTAssertEqual(try restored.scalarInt("SELECT COUNT(*) FROM portfolios"), 1)
        // Foreign keys are re-enabled after deserialisation.
        XCTAssertThrowsError(try restored.run("INSERT INTO watchlist_items (watchlist_id, instrument_id, added_at) VALUES ('nope','nope','x')"))
        XCTAssertThrowsError(try SQLiteDatabase(image: Data(repeating: 0, count: 4096)))
    }

    func testTransactionRollback() throws {
        let db = try migratedUserDatabase()
        XCTAssertThrowsError(try db.transaction {
            _ = try self.insertPortfolio(db)
            throw SQLiteError.serializationFailed
        })
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM portfolios"), 0)
    }

    func testCacheSchemaMigrates() throws {
        let db = try SQLiteDatabase()
        XCTAssertEqual(try Migrator.migrate(db, migrations: CacheSchema.migrations, now: fixedNow), [1])
        XCTAssertEqual(try db.integrityCheck(), [])
    }
}
