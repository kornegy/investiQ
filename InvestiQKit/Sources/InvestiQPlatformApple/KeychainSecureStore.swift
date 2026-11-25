#if canImport(Security)
import Foundation
import Security
import InvestiQSecurity

/// `SecureStore` backed by the macOS Keychain (generic password items).
///
/// Prefers the Data Protection Keychain (available when the app is signed with a team ID) and falls
/// back to the file-based login keychain for locally signed builds. Reads check both, so items are
/// never "lost" when the signing configuration changes (docs/SECURITY.md §5).
public struct KeychainSecureStore: SecureStore {
    public let servicePrefix: String
    private let preferDataProtection: Bool

    public init(servicePrefix: String) {
        self.servicePrefix = servicePrefix
        self.preferDataProtection = KeychainProbe.dataProtectionKeychainAvailable(servicePrefix: servicePrefix)
    }

    private func serviceName(_ service: SecureStoreService) -> String { "\(servicePrefix).\(service.rawValue)" }

    private func query(_ service: SecureStoreService, _ account: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(service),
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private var keychains: [Bool] { preferDataProtection ? [true, false] : [false] }

    public func data(service: SecureStoreService, account: String) throws -> Data? {
        for dataProtection in keychains {
            var request = query(service, account, dataProtection: dataProtection)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            switch status {
            case errSecSuccess: return result as? Data
            case errSecItemNotFound: continue
            default: throw KeychainErrors.map(status)
            }
        }
        return nil
    }

    public func set(_ data: Data, service: SecureStoreService, account: String) throws {
        let dataProtection = preferDataProtection
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let base = query(service, account, dataProtection: dataProtection)
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainErrors.map(status) }
        // Remove a stale copy from the other keychain so reads are unambiguous.
        if dataProtection { SecItemDelete(query(service, account, dataProtection: false) as CFDictionary) }
    }

    public func remove(service: SecureStoreService, account: String) throws {
        for dataProtection in keychains {
            let status = SecItemDelete(query(service, account, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainErrors.map(status) }
        }
    }

    public func accounts(service: SecureStoreService) throws -> [String] {
        var accounts = Set<String>()
        for dataProtection in keychains {
            var request = query(service, nil, dataProtection: dataProtection)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                for item in (result as? [[String: Any]]) ?? [] {
                    if let account = item[kSecAttrAccount as String] as? String { accounts.insert(account) }
                }
            case errSecItemNotFound: continue
            default: throw KeychainErrors.map(status)
            }
        }
        return accounts.sorted()
    }
}

enum KeychainErrors {
    static func map(_ status: OSStatus) -> SecureStoreError {
        switch status {
        case errSecMissingEntitlement: return .missingEntitlement
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecUserCanceled: return .userCancelled
        case errSecItemNotFound: return .itemNotFound
        default: return .unexpectedStatus(status)
        }
    }
}

enum KeychainProbe {
    /// The Data Protection Keychain requires a signed app with keychain entitlements; ad-hoc builds
    /// get `errSecMissingEntitlement`. Probe once by adding and deleting a throwaway item.
    static func dataProtectionKeychainAvailable(servicePrefix: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data([0])
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
#endif
