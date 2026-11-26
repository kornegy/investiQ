import Foundation
import Observation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

@MainActor
@Observable
public final class SecuritySettingsViewModel {
    public var currentPassword = ""
    public var newPassword = ""
    public var newPasswordConfirmation = ""
    public var deletionPassword = ""
    public private(set) var biometricAvailability: BiometricAvailability = .notSupported
    public private(set) var biometricEnabled = false
    public private(set) var message: Message?
    public private(set) var isBusy = false

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var autoLockMinutes: Int { app.preferences.autoLockMinutes }
    public var newPasswordIssues: [PasswordIssue] {
        guard !newPassword.isEmpty else { return [] }
        return PasswordPolicy().issues(password: newPassword, confirmation: newPasswordConfirmation)
            .filter { $0 != .confirmationMismatch || !newPasswordConfirmation.isEmpty }
    }

    public func load() async {
        biometricAvailability = await app.profileService.biometricAvailability()
        if let id = app.unlockedProfile?.summary.id {
            biometricEnabled = await app.profileService.isBiometricUnlockEnabled(id: id)
        }
    }

    public func setAutoLock(minutes: Int) async {
        guard UserPreferences.autoLockChoices.contains(minutes) else { return }
        do {
            try await app.updatePreferences { $0.autoLockMinutes = minutes }
        } catch {
            message = Message("settings.error.saveFailed")
        }
    }

    public func setBiometricUnlock(_ enabled: Bool) async {
        guard let profile = app.unlockedProfile else { return }
        do {
            try await app.profileService.setBiometricUnlock(enabled: enabled, profile: profile)
            biometricEnabled = enabled
            message = Message(enabled ? "settings.security.biometricEnabled" : "settings.security.biometricDisabled")
        } catch {
            message = AuthMessages.message(for: error)
            await load()
        }
    }

    public func changePassword() async {
        guard let id = app.unlockedProfile?.summary.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await app.profileService.changePassword(id: id, current: currentPassword, new: newPassword,
                                                        confirmation: newPasswordConfirmation)
            message = Message("settings.security.passwordChanged")
        } catch {
            message = AuthMessages.message(for: error)
        }
        currentPassword = ""
        newPassword = ""
        newPasswordConfirmation = ""
    }

    /// Deletes the profile (crypto-shredding) after password confirmation, then locks the app.
    public func deleteProfile() async {
        guard let id = app.unlockedProfile?.summary.id else { return }
        isBusy = true
        defer { isBusy = false }
        let password = deletionPassword
        deletionPassword = ""
        do {
            // Verify first, then close the session (flushes and stops all writers), then delete.
            _ = try await app.profileService.unlock(id: id, password: password)
            await app.lock(reason: .manual)
            try await app.profileService.deleteProfile(id: id, password: password)
            await app.bootstrap()
        } catch {
            message = AuthMessages.message(for: error)
        }
    }
}
