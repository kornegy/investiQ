import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

/// Maps authentication errors to localisable messages (no UI strings in logic, ADR-012).
enum AuthMessages {
    static func message(for error: any Error) -> Message {
        switch error as? ProfileError {
        case .wrongPassword(let remaining):
            return remaining > 0
                ? Message("auth.error.wrongPasswordRemaining", [.integer(remaining)])
                : Message("auth.error.wrongPassword")
        case .lockedOut(let until):
            return Message("auth.error.lockedOut", [.instant(until)])
        case .weakPassword:
            // The individual issues are listed next to the field (password.issue.*).
            return Message("auth.error.weakPassword")
        case .invalidDisplayName:
            return Message("auth.error.invalidDisplayName", [.integer(ProfileService.maximumDisplayNameLength)])
        case .biometricUnavailable(let availability):
            return Message("auth.error.biometric.\(availabilityKey(availability))")
        case .biometricNotEnabled:
            return Message("auth.error.biometricNotEnabled")
        case .biometricFailed:
            return Message("auth.error.biometricFailed")
        case .keyMissing:
            return Message("auth.error.keyMissing")
        case .notFound:
            return Message("auth.error.profileNotFound")
        case nil:
            return Message("error.generic")
        }
    }

    static func availabilityKey(_ availability: BiometricAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .notEnrolled: return "notEnrolled"
        case .notSupported: return "notSupported"
        case .entitlementMissing: return "entitlementMissing"
        case .lockedOut: return "lockedOut"
        }
    }
}

public extension BiometricAvailability {
    /// Suffix of the `auth.error.biometric.*` localisation keys.
    var localizationSuffix: String { AuthMessages.availabilityKey(self) }
}
