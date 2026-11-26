import XCTest
@testable import InvestiQPersistence
import InvestiQCore
import InvestiQSecurity
import InvestiQTestSupport

final class EncryptedStoreTests: XCTestCase {
    func testWriteReadRoundTripAndPlaintextNeverOnDisk() throws {
        let dir = try TemporaryDirectory()
        let profile = ProfileID()
        let key = CryptoBox.randomKey()
        let file = EncryptedDatabaseFile(url: dir.url.appendingPathComponent("user.iqdb"), kind: .user, profileID: profile, key: key)
        let db = try SQLiteDatabase()
        try db.execute("CREATE TABLE secrets (v TEXT); INSERT INTO secrets VALUES ('MY-SECRET-HOLDING');")
        try file.write(image: try db.serialize(), schemaVersion: 7)

        let raw = try Data(contentsOf: file.url)
        XCTAssertEqual(raw.prefix(4), Data("IQDB".utf8))
        XCTAssertNil(raw.range(of: Data("MY-SECRET-HOLDING".utf8)), "plaintext must not appear in the file")
        XCTAssertNil(raw.range(of: Data("SQLite format 3".utf8)))

        let loaded = try XCTUnwrap(try file.read())
        XCTAssertEqual(loaded.schemaVersion, 7)
        let restored = try SQLiteDatabase(image: loaded.image)
        XCTAssertEqual(try restored.queryOne("SELECT v FROM secrets")?.optionalString("v"), "MY-SECRET-HOLDING")
    }

    func testTamperWrongKeyAndWrongProfileAreRejected() throws {
        let dir = try TemporaryDirectory()
        let profile = ProfileID()
        let key = CryptoBox.randomKey()
        let url = dir.url.appendingPathComponent("user.iqdb")
        let file = EncryptedDatabaseFile(url: url, kind: .user, profileID: profile, key: key)
        try file.write(image: try SQLiteDatabase().serialize(), schemaVersion: 1)

        XCTAssertThrowsError(try EncryptedDatabaseFile(url: url, kind: .user, profileID: profile, key: CryptoBox.randomKey()).read()) {
            XCTAssertEqual($0 as? EncryptedFileError, .decryptionFailed)
        }
        XCTAssertThrowsError(try EncryptedDatabaseFile(url: url, kind: .user, profileID: ProfileID(), key: key).read()) {
            XCTAssertEqual($0 as? EncryptedFileError, .profileMismatch)
        }
        XCTAssertThrowsError(try EncryptedDatabaseFile(url: url, kind: .cache, profileID: profile, key: key).read()) {
            XCTAssertEqual($0 as? EncryptedFileError, .wrongContentKind)
        }
        // Flip one bit in the header (schema version) — authenticated as AAD, so decryption fails.
        var bytes = try Data(contentsOf: url)
        bytes[31] ^= 0x01
        try bytes.write(to: url)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? EncryptedFileError, .decryptionFailed) }
        try Data("not a db".utf8).write(to: url)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? EncryptedFileError, .notAnInvestiQDatabase) }
    }

    func testPreviousGenerationIsUsedWhenMainFileIsMissing() throws {
        let dir = try TemporaryDirectory()
        let file = EncryptedDatabaseFile(url: dir.url.appendingPathComponent("user.iqdb"), kind: .user, profileID: ProfileID(), key: CryptoBox.randomKey())
        try file.write(image: try SQLiteDatabase().serialize(), schemaVersion: 1)
        try file.write(image: try SQLiteDatabase().serialize(), schemaVersion: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.backupURL.path))
        try FileManager.default.removeItem(at: file.url) // simulate crash between the two renames
        XCTAssertEqual(try file.read()?.schemaVersion, 1)
    }

    func testDatabaseStorePersistsAcrossReopen() async throws {
        let dir = try TemporaryDirectory()
        let profile = ProfileID()
        let key = CryptoBox.randomKey()
        let file = EncryptedDatabaseFile(url: dir.url.appendingPathComponent("user.iqdb"), kind: .user, profileID: profile, key: key)
        let store = try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        try await store.write { db in
            try db.run("INSERT INTO portfolios (id, name, kind, base_currency, created_at) VALUES ('p','Main','real','CZK','x')")
        }
        let reopened = try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        let count = try await reopened.read { try $0.scalarInt("SELECT COUNT(*) FROM portfolios") }
        XCTAssertEqual(count, 1)
        let problems = try await reopened.integrityCheck()
        XCTAssertEqual(problems, [])
    }

    func testFailedWriteDoesNotPersistPartialChanges() async throws {
        let dir = try TemporaryDirectory()
        let file = EncryptedDatabaseFile(url: dir.url.appendingPathComponent("user.iqdb"), kind: .user, profileID: ProfileID(), key: CryptoBox.randomKey())
        let store = try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        do {
            try await store.write { db in
                try db.run("INSERT INTO portfolios (id, name, kind, base_currency, created_at) VALUES ('p','Main','real','CZK','x')")
                try db.run("INSERT INTO portfolios (id, name, kind, base_currency, created_at) VALUES ('q','Main','real','CZK','x')") // UNIQUE(name, kind)
            }
            XCTFail("expected constraint violation")
        } catch {}
        let reopened = try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        let count = try await reopened.read { try $0.scalarInt("SELECT COUNT(*) FROM portfolios") }
        XCTAssertEqual(count, 0)
    }

    func testInMemoryStoreNeverWritesFiles() async throws {
        let store = try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        try await store.write { try $0.run("INSERT INTO watchlists (id, name, created_at) VALUES ('w','Demo','x')") }
        try await store.persistNow()
        let count = try await store.read { try $0.scalarInt("SELECT COUNT(*) FROM watchlists") }
        XCTAssertEqual(count, 1)
    }
}
