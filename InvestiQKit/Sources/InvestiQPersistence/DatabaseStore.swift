import Foundation
import InvestiQCore

/// Owns one in-memory SQLite database and its encrypted file. All access is serialised by the actor.
///
/// * `user` stores persist synchronously after every committed write (no lost acknowledged changes).
/// * `cache` stores persist debounced (data is regenerable).
/// * Stores without a file (demo mode, tests) never touch the disk.
public actor DatabaseStore {
    public enum PersistencePolicy: Sendable {
        case immediate
        case debounced(seconds: Double)
        case inMemoryOnly
    }

    private let database: SQLiteDatabase
    private let file: EncryptedDatabaseFile?
    private let policy: PersistencePolicy
    private var pendingSave: Task<Void, Never>?
    private var dirty = false
    public private(set) var lastSaveError: String?

    /// Opens (decrypts + migrates) or creates a store.
    public init(file: EncryptedDatabaseFile?, migrations: [Migration], policy: PersistencePolicy, now: Date) throws {
        let database: SQLiteDatabase
        if let file, let stored = try file.read() {
            database = try SQLiteDatabase(image: stored.image)
        } else {
            database = try SQLiteDatabase()
        }
        let applied = try Migrator.migrate(database, migrations: migrations, now: now)
        self.database = database
        self.file = file
        self.policy = file == nil ? .inMemoryOnly : policy
        if !applied.isEmpty, let file {
            try file.write(image: try database.serialize(), schemaVersion: database.userVersion)
        }
    }

    /// Read-only access. The closure must not start a transaction or modify data.
    public func read<T: Sendable>(_ body: @Sendable (SQLiteDatabase) throws -> T) throws -> T {
        try body(database)
    }

    /// Transactional write, then persistence according to the policy.
    @discardableResult
    public func write<T: Sendable>(_ body: @Sendable (SQLiteDatabase) throws -> T) throws -> T {
        let value = try database.transaction { try body(database) }
        try afterWrite()
        return value
    }

    private func afterWrite() throws {
        switch policy {
        case .inMemoryOnly:
            return
        case .immediate:
            try persistNow()
        case .debounced(let seconds):
            dirty = true
            pendingSave?.cancel()
            pendingSave = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.flushIfDirty()
            }
        }
    }

    private func flushIfDirty() {
        guard dirty else { return }
        do {
            try persistNow()
        } catch {
            // Cache persistence failures are not fatal (data is regenerable) but are surfaced.
            lastSaveError = String(describing: error)
        }
    }

    /// Writes the encrypted image now (also used before backup and on lock).
    public func persistNow() throws {
        guard let file else { return }
        try file.write(image: try database.serialize(), schemaVersion: database.userVersion)
        dirty = false
        lastSaveError = nil
    }

    /// Flushes pending debounced writes (called when locking the app).
    public func close() {
        pendingSave?.cancel()
        flushIfDirty()
    }

    public func image() throws -> Data { try database.serialize() }

    public func schemaVersion() -> Int { database.userVersion }

    public func integrityCheck() throws -> [String] { try database.integrityCheck() }
}
