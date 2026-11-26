import Foundation

/// Storage for small secrets (key envelopes, API keys, throttle state).
/// The app uses the macOS Keychain (`InvestiQPlatformApple.KeychainSecureStore`); tests use
/// `InMemorySecureStore`.
public protocol SecureStore: Sendable {
    func data(service: SecureStoreService, account: String) throws -> Data?
    func set(_ data: Data, service: SecureStoreService, account: String) throws
    func remove(service: SecureStoreService, account: String) throws
    func accounts(service: SecureStoreService) throws -> [String]
}

/// Logical Keychain services. The platform store prefixes them with the bundle identifier.
public enum SecureStoreService: String, Sendable, CaseIterable {
    case keyEnvelope = "key-envelope"
    case authThrottle = "auth-throttle"
    case apiKey = "api-key"
}

public enum SecureStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case missingEntitlement
    case interactionNotAllowed
    case userCancelled
    case itemNotFound
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    private func key(_ service: SecureStoreService, _ account: String) -> String { "\(service.rawValue)|\(account)" }

    public func data(service: SecureStoreService, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account)]
    }

    public func set(_ data: Data, service: SecureStoreService, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account)] = data
    }

    public func remove(service: SecureStoreService, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account)] = nil
    }

    public func accounts(service: SecureStoreService) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(service.rawValue)|"
        return items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
}

/// Biometric-protected key storage (Touch ID). The OS performs the biometric check; the app never
/// sees biometric data (spec §6).
public protocol BiometricKeyStore: Sendable {
    func availability() -> BiometricAvailability
    func storeKey(_ key: Data, account: String) throws
    func retrieveKey(account: String, reason: String) async throws -> Data
    func removeKey(account: String) throws
    func hasKey(account: String) -> Bool
}

public enum BiometricAvailability: Equatable, Sendable, CaseIterable {
    case available
    case notEnrolled
    case notSupported
    /// The build is not signed with entitlements that allow the Data Protection Keychain.
    case entitlementMissing
    case lockedOut
}

/// Placeholder used where no biometric hardware/API exists (Linux tests, demo).
public struct UnavailableBiometricKeyStore: BiometricKeyStore {
    public init() {}
    public func availability() -> BiometricAvailability { .notSupported }
    public func storeKey(_ key: Data, account: String) throws { throw SecureStoreError.missingEntitlement }
    public func retrieveKey(account: String, reason: String) async throws -> Data { throw SecureStoreError.itemNotFound }
    public func removeKey(account: String) throws {}
    public func hasKey(account: String) -> Bool { false }
}
