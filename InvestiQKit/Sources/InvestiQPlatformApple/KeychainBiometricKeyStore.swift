#if canImport(LocalAuthentication) && canImport(Security)
import Foundation
import LocalAuthentication
import Security
import InvestiQSecurity

/// Stores a profile's data key in the Data Protection Keychain with `.biometryCurrentSet` access
/// control. The system performs the Touch ID check; the app never handles biometric data, and a
/// changed fingerprint set invalidates the item (docs/SECURITY.md §3).
public struct KeychainBiometricKeyStore: BiometricKeyStore {
    private let service: String
    private let servicePrefix: String

    public init(servicePrefix: String) {
        self.servicePrefix = servicePrefix
        self.service = "\(servicePrefix).biometric-key"
    }

    public func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
            case .biometryNotEnrolled: return .notEnrolled
            case .biometryLockout: return .lockedOut
            default: return .notSupported
            }
        }
        return KeychainProbe.dataProtectionKeychainAvailable(servicePrefix: servicePrefix) ? .available : .entitlementMissing
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func storeKey(_ key: Data, account: String) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .biometryCurrentSet, &accessError) else {
            throw SecureStoreError.unexpectedStatus(errSecParam)
        }
        try removeKey(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainErrors.map(status) }
    }

    public func retrieveKey(account: String, reason: String) async throws -> Data {
        let query = baseQuery(account: account)
        // SecItemCopyMatching blocks while the system shows the Touch ID sheet, so run it off the main thread.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                var request = query
                request[kSecReturnData as String] = true
                request[kSecMatchLimit as String] = kSecMatchLimitOne
                request[kSecUseAuthenticationContext as String] = context
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                if status == errSecSuccess, let data = result as? Data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: KeychainErrors.map(status))
                }
            }
        }
    }

    public func removeKey(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw KeychainErrors.map(status)
        }
    }

    /// Checks for the item without triggering a Touch ID prompt.
    public func hasKey(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
#endif
