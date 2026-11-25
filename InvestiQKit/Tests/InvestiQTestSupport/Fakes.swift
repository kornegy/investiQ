import Foundation
import InvestiQCore
import InvestiQSecurity

/// Biometric store fake: "Touch ID" succeeds unless `shouldFail` is set.
public final class FakeBiometricKeyStore: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    public var currentAvailability: BiometricAvailability
    public var shouldFail = false

    public init(availability: BiometricAvailability = .available) { currentAvailability = availability }

    public func availability() -> BiometricAvailability { currentAvailability }

    public func storeKey(_ key: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[account] = key
    }

    public func retrieveKey(account: String, reason: String) async throws -> Data {
        let key: Data? = lock.withLock { keys[account] }
        guard !shouldFail, let key else { throw SecureStoreError.userCancelled }
        return key
    }

    public func removeKey(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[account] = nil
    }

    public func hasKey(account: String) -> Bool { lock.withLock { keys[account] != nil } }
}
