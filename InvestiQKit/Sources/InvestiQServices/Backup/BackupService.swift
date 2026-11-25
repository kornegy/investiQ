import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQPersistence

public enum BackupServiceError: Error, Equatable, Sendable {
    case weakPassphrase([PasswordIssue])
    case notAvailableInDemo
    case file(BackupFile.BackupError)
    case newerThanApp
    case damaged
}

public struct BackupSummary: Sendable, Equatable {
    public var createdAt: Date
    public var schemaVersion: Int
    public var portfolios: Int
    public var transactions: Int
    public var displayName: String?
}

/// Encrypted backup and restore of the profile's user database (spec §6, §25). The cache database is
/// not included (it is regenerable); API keys stay in the Keychain.
public actor BackupService {
    private let store: DatabaseStore
    private let derivation: any PasswordKeyDerivation
    private let isDemo: Bool
    private let clock: any TimeProvider

    public init(store: DatabaseStore, derivation: any PasswordKeyDerivation, isDemo: Bool, clock: any TimeProvider) {
        self.store = store
        self.derivation = derivation
        self.isDemo = isDemo
        self.clock = clock
    }

    public func createBackup(passphrase: String, confirmation: String) async throws -> Data {
        guard !isDemo else { throw BackupServiceError.notAvailableInDemo }
        let issues = PasswordPolicy().issues(password: passphrase, confirmation: confirmation)
        guard issues.isEmpty else { throw BackupServiceError.weakPassphrase(issues) }
        let image = try await store.image()
        let version = await store.schemaVersion()
        return try BackupFile.make(image: image, schemaVersion: version, passphrase: passphrase, derivation: derivation, now: clock.now())
    }

    /// Decrypts and validates without changing anything; returns what the backup contains.
    public func inspect(_ data: Data, passphrase: String) throws -> BackupSummary {
        let (header, image) = try open(data, passphrase: passphrase)
        let database: SQLiteDatabase
        do { database = try SQLiteDatabase(image: image) } catch { throw BackupServiceError.damaged }
        guard (try? database.integrityCheck())?.isEmpty == true else { throw BackupServiceError.damaged }
        let latest = UserSchema.migrations.map(\.version).max() ?? 0
        guard database.userVersion <= latest else { throw BackupServiceError.newerThanApp }
        func count(_ table: String) -> Int { Int((try? database.scalarInt("SELECT COUNT(*) FROM \(table)")) ?? 0 ?? 0) }
        let name = try? database.queryOne("SELECT display_name FROM user_profile WHERE singleton = 1")?.optionalString("display_name")
        return BackupSummary(createdAt: header.createdAt, schemaVersion: database.userVersion, portfolios: count("portfolios"),
                             transactions: count("transactions"), displayName: name ?? nil)
    }

    /// Replaces this profile's data with the backup. The previous encrypted generation is kept on disk.
    public func restore(_ data: Data, passphrase: String) async throws -> BackupSummary {
        guard !isDemo else { throw BackupServiceError.notAvailableInDemo }
        let summary = try inspect(data, passphrase: passphrase)
        let (_, image) = try open(data, passphrase: passphrase)
        do {
            try await store.replaceContents(with: image, migrations: UserSchema.migrations, now: clock.now())
        } catch is RestoreValidationError {
            throw BackupServiceError.damaged
        } catch let error as MigrationError {
            if case .databaseNewerThanApp = error { throw BackupServiceError.newerThanApp }
            throw BackupServiceError.damaged
        }
        return summary
    }

    private func open(_ data: Data, passphrase: String) throws -> (BackupFile.Header, Data) {
        do {
            return try BackupFile.open(data, passphrase: passphrase, derivation: derivation)
        } catch let error as BackupFile.BackupError {
            throw BackupServiceError.file(error)
        }
    }
}
