import XCTest
@testable import InvestiQServices
@testable import InvestiQPersistence
import InvestiQCore
import InvestiQSecurity
import InvestiQTestSupport

final class BackupTests: XCTestCase {
    let derivation = Argon2idKeyDerivation.testing
    let passphrase = "Zálohovací heslo 2026"

    func testBackupFileRoundTripAndTamperDetection() throws {
        let image = Data("database image".utf8)
        let file = try BackupFile.make(image: image, schemaVersion: 2, passphrase: passphrase, derivation: derivation, now: fixedNow)
        XCTAssertEqual(Data(file.prefix(4)), Data("IQBK".utf8))
        XCTAssertEqual(try BackupFile.header(of: file).schemaVersion, 2)
        XCTAssertEqual(try BackupFile.open(file, passphrase: passphrase, derivation: derivation).image, image)
        XCTAssertNil(file.range(of: image), "the payload is encrypted")
        XCTAssertThrowsError(try BackupFile.open(file, passphrase: "wrong passphrase!", derivation: derivation)) {
            XCTAssertEqual($0 as? BackupFile.BackupError, .wrongPassphraseOrDamaged)
        }
        var tamperedHeader = file
        let index = try XCTUnwrap(tamperedHeader.range(of: Data("\"schemaVersion\":2".utf8))).upperBound - 1
        tamperedHeader[index] = UInt8(ascii: "1")
        XCTAssertThrowsError(try BackupFile.open(tamperedHeader, passphrase: passphrase, derivation: derivation),
                             "the header is authenticated (associated data)")
        var tamperedBody = file
        tamperedBody[tamperedBody.count - 1] ^= 0xFF
        XCTAssertThrowsError(try BackupFile.open(tamperedBody, passphrase: passphrase, derivation: derivation))
        XCTAssertThrowsError(try BackupFile.header(of: Data("IQDB something".utf8))) { XCTAssertEqual($0 as? BackupFile.BackupError, .notABackup) }
    }

    func testCraftedKDFParametersAreRefused() throws {
        let hostile = Argon2idKeyDerivation(opsLimit: 1, memLimitBytes: 4 * 1024 * 1024 * 1024)
        let parameters = KDFParameters(algorithm: "argon2id13", opsLimit: 1, memLimitBytes: 4 * 1024 * 1024 * 1024, salt: Data(repeating: 1, count: 16))
        let header = BackupFile.Header(kdf: parameters, schemaVersion: 2, createdAt: fixedNow, contents: "userDatabase")
        let json = try BackupFile.encoder.encode(header)
        let length: [UInt8] = withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init)
        var data = Data("IQBK".utf8)
        data.append(contentsOf: [0, 1])
        data.append(contentsOf: length)
        data.append(json)
        data.append(Data(repeating: 0, count: 64))
        XCTAssertThrowsError(try BackupFile.open(data, passphrase: passphrase, derivation: hostile)) {
            XCTAssertEqual($0 as? BackupFile.BackupError, .notABackup, "4 GiB of Argon2 memory is never attempted")
        }
    }

    func makeStore(_ directory: TemporaryDirectory) throws -> (DatabaseStore, EncryptedDatabaseFile) {
        let file = EncryptedDatabaseFile(url: directory.url.appendingPathComponent("user.iqdb"), kind: .user, profileID: ProfileID(),
                                         key: CryptoBox.randomKey())
        return (try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow), file)
    }

    func testCreateModifyRestoreKeepsPreviousGeneration() async throws {
        let directory = try TemporaryDirectory()
        let (store, file) = try makeStore(directory)
        let portfolio = Portfolio(name: "Main", kind: .real, baseCurrency: .czk, createdAt: fixedNow)
        try await store.write { try PortfolioRecords.insert(portfolio, in: $0) }
        let service = BackupService(store: store, derivation: derivation, isDemo: false, clock: ManualTimeProvider(fixedNow))
        do {
            _ = try await service.createBackup(passphrase: "short", confirmation: "short")
            XCTFail("weak passphrases are refused")
        } catch BackupServiceError.weakPassphrase {}
        let backup = try await service.createBackup(passphrase: passphrase, confirmation: passphrase)

        let second = Portfolio(name: "Later", kind: .real, baseCurrency: .eur, createdAt: fixedNow)
        try await store.write { try PortfolioRecords.insert(second, in: $0) }
        let summary = try await service.inspect(backup, passphrase: passphrase)
        XCTAssertEqual(summary.portfolios, 1)
        let before = try await store.read { try PortfolioRecords.all(in: $0).count }
        XCTAssertEqual(before, 2, "inspect changes nothing")

        do {
            _ = try await service.restore(backup, passphrase: "Wrong passphrase 1")
            XCTFail("wrong passphrase")
        } catch BackupServiceError.file(.wrongPassphraseOrDamaged) {}
        _ = try await service.restore(backup, passphrase: passphrase)
        let names = try await store.read { try PortfolioRecords.all(in: $0).map(\.name) }
        XCTAssertEqual(names, ["Main"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.backupURL.path), "the previous generation stays on disk")
        // The restored state is what is on disk now.
        let reopened = try DatabaseStore(file: file, migrations: UserSchema.migrations, policy: .immediate, now: fixedNow)
        let persisted = try await reopened.read { try PortfolioRecords.all(in: $0).map(\.name) }
        XCTAssertEqual(persisted, ["Main"])
    }

    func testOlderSchemaBackupIsMigratedAndDemoIsRefused() async throws {
        let old = try SQLiteDatabase()
        try Migrator.migrate(old, migrations: Array(UserSchema.migrations.prefix(1)), now: fixedNow)
        let backup = try BackupFile.make(image: try old.serialize(), schemaVersion: 1, passphrase: passphrase, derivation: derivation, now: fixedNow)
        let directory = try TemporaryDirectory()
        let (store, _) = try makeStore(directory)
        let service = BackupService(store: store, derivation: derivation, isDemo: false, clock: ManualTimeProvider(fixedNow))
        _ = try await service.restore(backup, passphrase: passphrase)
        let version = await store.schemaVersion()
        XCTAssertEqual(version, UserSchema.migrations.map(\.version).max())

        let demo = BackupService(store: store, derivation: derivation, isDemo: true, clock: ManualTimeProvider(fixedNow))
        do {
            _ = try await demo.createBackup(passphrase: passphrase, confirmation: passphrase)
            XCTFail("demo sessions have nothing to back up")
        } catch BackupServiceError.notAvailableInDemo {}
    }

    func testExportContainsUserDataButNoSecrets() async throws {
        let directory = try TemporaryDirectory()
        let (store, _) = try makeStore(directory)
        let portfolio = Portfolio(name: "Main", kind: .real, baseCurrency: .czk, createdAt: fixedNow)
        try await store.write { db in
            try PortfolioRecords.insert(portfolio, in: db)
            try TransactionRecords.insert(Transaction(portfolioID: portfolio.id, type: .deposit, tradeDate: .d("2026-01-05"), amount: 1000,
                                                      currency: .czk, createdAt: fixedNow), in: db)
        }
        let json = try await DataExportService(store: store, clock: ManualTimeProvider(fixedNow)).exportJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let portfolios = try XCTUnwrap(object["portfolios"] as? [[String: Any]])
        XCTAssertEqual((portfolios.first?["transactions"] as? [Any])?.count, 1)
        let text = String(decoding: json, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("apikey") || text.contains("password") || text.contains("envelope"))
    }
}
