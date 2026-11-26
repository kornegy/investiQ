import Foundation
import Observation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

@MainActor
@Observable
public final class LockScreenViewModel {
    public var selectedProfileID: ProfileID?
    public var password = ""
    public private(set) var isBusy = false
    public private(set) var error: Message?
    public private(set) var lockedUntil: Date?
    public private(set) var biometricEnabledForSelection = false

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var profiles: [ProfileSummary] { app.profiles }
    public var canSubmit: Bool { !isBusy && selectedProfileID != nil && !password.isEmpty && !isLockedOut }
    public var isLockedOut: Bool {
        guard let lockedUntil else { return false }
        return lockedUntil > app.environment.clock.now()
    }

    public func onAppear() async {
        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id
        }
        await refreshStatus()
    }

    public func refreshStatus() async {
        guard let id = selectedProfileID else { return }
        do {
            if case .locked(let until) = try await app.profileService.throttleDecision(for: id) {
                lockedUntil = until
            } else {
                lockedUntil = nil
            }
        } catch {
            lockedUntil = nil
        }
        let availability = await app.profileService.biometricAvailability()
        let enabled = await app.profileService.isBiometricUnlockEnabled(id: id)
        biometricEnabledForSelection = availability == .available && enabled
    }

    public func unlock() async {
        guard let id = selectedProfileID, canSubmit else { return }
        isBusy = true
        defer { isBusy = false }
        let attempt = password
        password = "" // never keep the password around longer than needed
        do {
            let unlocked = try await app.profileService.unlock(id: id, password: attempt)
            error = nil
            lockedUntil = nil
            await app.didUnlock(unlocked)
        } catch {
            if case ProfileError.lockedOut(let until) = error { lockedUntil = until }
            self.error = AuthMessages.message(for: error)
        }
    }

    /// `reason` is the localised text shown by the system Touch ID prompt.
    public func unlockWithBiometrics(reason: String) async {
        guard let id = selectedProfileID, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let unlocked = try await app.profileService.unlockWithBiometrics(id: id, reason: reason)
            error = nil
            await app.didUnlock(unlocked)
        } catch {
            self.error = AuthMessages.message(for: error)
        }
    }
}
