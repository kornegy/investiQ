import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQPersistence

public enum SessionMode: String, Sendable { case real, demo }

/// The open databases of one unlocked profile (or of the in-memory demo).
/// Dropping the session releases the keys held by the stores (docs/ARCHITECTURE.md §3.1).
public final class ProfileSession: Sendable {
    public let profileID: ProfileID
    public let displayName: String
    public let mode: SessionMode
    public let userStore: DatabaseStore
    public let cacheStore: DatabaseStore

    init(profileID: ProfileID, displayName: String, mode: SessionMode, userStore: DatabaseStore, cacheStore: DatabaseStore) {
        self.profileID = profileID
        self.displayName = displayName
        self.mode = mode
        self.userStore = userStore
        self.cacheStore = cacheStore
    }

    /// Cache saves are debounced; user data is saved after each write.
    static let cacheSaveDelaySeconds = 3.0

    public static func open(_ unlocked: UnlockedProfile, paths: ProfilePaths, clock: any TimeProvider) throws -> ProfileSession {
        let id = unlocked.summary.id
        let userFile = EncryptedDatabaseFile(url: paths.userDatabase(for: id), kind: .user, profileID: id,
                                             key: unlocked.databaseKey(purpose: KeyPurpose.userDatabase))
        let cacheFile = EncryptedDatabaseFile(url: paths.cacheDatabase(for: id), kind: .cache, profileID: id,
                                              key: unlocked.databaseKey(purpose: KeyPurpose.cacheDatabase))
        let userStore = try DatabaseStore(file: userFile, migrations: UserSchema.migrations, policy: .immediate, now: clock.now())
        let cacheStore: DatabaseStore
        do {
            cacheStore = try DatabaseStore(file: cacheFile, migrations: CacheSchema.migrations,
                                           policy: .debounced(seconds: cacheSaveDelaySeconds), now: clock.now())
        } catch {
            // The cache is regenerable: a corrupted cache is replaced instead of blocking the user.
            try? FileManager.default.removeItem(at: cacheFile.url)
            try? FileManager.default.removeItem(at: cacheFile.backupURL)
            cacheStore = try DatabaseStore(file: cacheFile, migrations: CacheSchema.migrations,
                                           policy: .debounced(seconds: cacheSaveDelaySeconds), now: clock.now())
        }
        return ProfileSession(profileID: id, displayName: unlocked.summary.displayName, mode: .real,
                              userStore: userStore, cacheStore: cacheStore)
    }

    /// In-memory demo session; never written to disk (ADR-008).
    public static func demo(clock: any TimeProvider) throws -> ProfileSession {
        ProfileSession(profileID: ProfileID(), displayName: "Demo", mode: .demo,
                       userStore: try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .inMemoryOnly, now: clock.now()),
                       cacheStore: try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: clock.now()))
    }

    public func close() async {
        await cacheStore.close()
    }
}

/// Profile-level data stored in the user database.
public struct ProfileDataService: Sendable {
    let store: DatabaseStore
    public init(session: ProfileSession) { store = session.userStore }

    public func profile() async throws -> UserProfile? { try await store.read { try ProfileRecords.load(from: $0) } }
    public func saveProfile(_ profile: UserProfile) async throws { try await store.write { try ProfileRecords.save(profile, in: $0) } }
    public func preferences() async throws -> UserPreferences { try await store.read { try PreferenceRecords.loadPreferences(from: $0) } }
    public func savePreferences(_ preferences: UserPreferences) async throws {
        try await store.write { try PreferenceRecords.savePreferences(preferences, in: $0) }
    }
    public func financialProfile() async throws -> FinancialProfile? { try await store.read { try FinancialProfileRecords.load(from: $0) } }
    public func saveFinancialProfile(_ profile: FinancialProfile) async throws {
        try await store.write { try FinancialProfileRecords.save(profile, in: $0) }
    }
}
