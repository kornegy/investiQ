import Foundation
import InvestiQCore
import InvestiQSecurity
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ProfileError: Error, Equatable, Sendable {
    case notFound
    case invalidDisplayName
    case weakPassword([PasswordIssue])
    case wrongPassword(remainingFreeAttempts: Int)
    case lockedOut(until: Date)
    case biometricUnavailable(BiometricAvailability)
    case biometricNotEnabled
    case biometricFailed
    case keyMissing
}

/// A profile whose data-encryption key is available in memory (unlocked).
public struct UnlockedProfile: Sendable {
    public let summary: ProfileSummary
    let dataKey: SymmetricKey

    /// Sub-key for one database (HKDF), so the DEK itself never encrypts data directly.
    func databaseKey(purpose: String) -> SymmetricKey { CryptoBox.deriveKey(from: dataKey, purpose: purpose) }
}

/// Local profile management: creation, unlocking, password change, Touch ID, deletion
/// (docs/SECURITY.md §3–4). All key derivation runs on this actor, never on the main thread.
public actor ProfileService {
    private let paths: ProfilePaths
    private let secureStore: any SecureStore
    private let biometricStore: any BiometricKeyStore
    private let derivation: any PasswordKeyDerivation
    private let clock: any TimeProvider
    private let throttlePolicy: LoginThrottlePolicy
    private var registry: ProfileRegistry { ProfileRegistry(url: paths.registryURL) }

    public static let maximumDisplayNameLength = 50

    public init(paths: ProfilePaths, secureStore: any SecureStore, biometricStore: any BiometricKeyStore,
                derivation: any PasswordKeyDerivation, clock: any TimeProvider,
                throttlePolicy: LoginThrottlePolicy = LoginThrottlePolicy()) {
        self.paths = paths
        self.secureStore = secureStore
        self.biometricStore = biometricStore
        self.derivation = derivation
        self.clock = clock
        self.throttlePolicy = throttlePolicy
    }

    public func profiles() throws -> [ProfileSummary] { try registry.load() }

    private func throttle(_ id: ProfileID) -> LoginThrottle {
        LoginThrottle(store: secureStore, account: id.string, policy: throttlePolicy, clock: clock)
    }

    public func throttleDecision(for id: ProfileID) throws -> LoginThrottleDecision { try throttle(id).decision() }

    public func createProfile(displayName: String, password: String, confirmation: String,
                              educationalMode: Bool = false) throws -> UnlockedProfile {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maximumDisplayNameLength).contains(name.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProfileError.invalidDisplayName
        }
        let issues = PasswordPolicy().issues(password: password, confirmation: confirmation)
        guard issues.isEmpty else { throw ProfileError.weakPassword(issues) }

        let id = ProfileID()
        let dataKey = CryptoBox.randomKey()
        let envelope = try KeyEnvelope.create(dataKey: dataKey, password: password, profileID: id,
                                              derivation: derivation, now: clock.now())
        try secureStore.set(try envelope.encoded(), service: .keyEnvelope, account: id.string)
        let summary = ProfileSummary(id: id, displayName: name, createdAt: clock.now(), educationalMode: educationalMode)
        do {
            try FileManager.default.createDirectory(at: paths.directory(for: id), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try registry.save(try registry.load() + [summary])
        } catch {
            try? secureStore.remove(service: .keyEnvelope, account: id.string) // roll back the key on failure
            throw error
        }
        return UnlockedProfile(summary: summary, dataKey: dataKey)
    }

    private func envelope(for id: ProfileID) throws -> KeyEnvelope {
        guard let data = try secureStore.data(service: .keyEnvelope, account: id.string) else { throw ProfileError.keyMissing }
        return try KeyEnvelope.decode(data)
    }

    private func summary(for id: ProfileID) throws -> ProfileSummary {
        guard let summary = try registry.load().first(where: { $0.id == id }) else { throw ProfileError.notFound }
        return summary
    }

    public func unlock(id: ProfileID, password: String) throws -> UnlockedProfile {
        let summary = try summary(for: id)
        let throttle = throttle(id)
        if case .locked(let until) = try throttle.decision() { throw ProfileError.lockedOut(until: until) }
        do {
            let key = try envelope(for: id).unwrap(password: password, derivation: derivation)
            try throttle.recordSuccess()
            return UnlockedProfile(summary: summary, dataKey: key)
        } catch KeyEnvelopeError.wrongPassword {
            switch try throttle.recordFailure() {
            case .locked(let until): throw ProfileError.lockedOut(until: until)
            case .allowed(let remaining): throw ProfileError.wrongPassword(remainingFreeAttempts: remaining)
            }
        }
    }

    public func unlockWithBiometrics(id: ProfileID, reason: String) async throws -> UnlockedProfile {
        let summary = try summary(for: id)
        let availability = biometricStore.availability()
        guard availability == .available else { throw ProfileError.biometricUnavailable(availability) }
        guard biometricStore.hasKey(account: id.string) else { throw ProfileError.biometricNotEnabled }
        let raw: Data
        do {
            raw = try await biometricStore.retrieveKey(account: id.string, reason: reason)
        } catch {
            throw ProfileError.biometricFailed
        }
        let key = try CryptoBox.key(from: raw)
        try throttle(id).recordSuccess()
        return UnlockedProfile(summary: summary, dataKey: key)
    }

    public func isBiometricUnlockEnabled(id: ProfileID) -> Bool { biometricStore.hasKey(account: id.string) }

    public func biometricAvailability() -> BiometricAvailability { biometricStore.availability() }

    /// Enabling stores a copy of the DEK in the biometric-protected keychain item (requires an unlocked profile).
    public func setBiometricUnlock(enabled: Bool, profile: UnlockedProfile) throws {
        if enabled {
            let availability = biometricStore.availability()
            guard availability == .available else { throw ProfileError.biometricUnavailable(availability) }
            try biometricStore.storeKey(CryptoBox.keyData(profile.dataKey), account: profile.summary.id.string)
        } else {
            try biometricStore.removeKey(account: profile.summary.id.string)
        }
    }

    /// Re-wraps the DEK with the new password. Data files are not re-encrypted (the DEK is unchanged).
    public func changePassword(id: ProfileID, current: String, new: String, confirmation: String) throws {
        let issues = PasswordPolicy().issues(password: new, confirmation: confirmation)
        guard issues.isEmpty else { throw ProfileError.weakPassword(issues) }
        let unlocked = try unlock(id: id, password: current)
        let envelope = try KeyEnvelope.create(dataKey: unlocked.dataKey, password: new, profileID: id,
                                              derivation: derivation, now: clock.now())
        try secureStore.set(try envelope.encoded(), service: .keyEnvelope, account: id.string)
    }

    public func updateSummary(_ summary: ProfileSummary) throws {
        var all = try registry.load()
        guard let index = all.firstIndex(where: { $0.id == summary.id }) else { throw ProfileError.notFound }
        all[index] = summary
        try registry.save(all)
    }

    /// Deletes a profile after password confirmation. Keys are removed first (crypto-shredding),
    /// then files (docs/SECURITY.md §3).
    public func deleteProfile(id: ProfileID, password: String) throws {
        _ = try unlock(id: id, password: password)
        try secureStore.remove(service: .keyEnvelope, account: id.string)
        try biometricStore.removeKey(account: id.string)
        try secureStore.remove(service: .authThrottle, account: id.string)
        for account in try secureStore.accounts(service: .apiKey) where account.hasPrefix(id.string + "/") {
            try secureStore.remove(service: .apiKey, account: account)
        }
        let directory = paths.directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try registry.save(try registry.load().filter { $0.id != id })
    }
}
