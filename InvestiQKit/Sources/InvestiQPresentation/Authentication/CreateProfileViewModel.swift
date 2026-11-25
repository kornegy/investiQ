import Foundation
import Observation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

@MainActor
@Observable
public final class CreateProfileViewModel {
    public var displayName = ""
    public var password = ""
    public var confirmation = ""
    public private(set) var isBusy = false
    public private(set) var error: Message?

    private let app: AppModel
    private let policy = PasswordPolicy()

    public init(app: AppModel) { self.app = app }

    /// Issues shown while typing (confirmation mismatch only once something was typed in it).
    public var issues: [PasswordIssue] {
        guard !password.isEmpty else { return [] }
        return policy.issues(password: password, confirmation: confirmation)
            .filter { $0 != .confirmationMismatch || !confirmation.isEmpty }
    }

    public var strength: PasswordStrength { policy.strength(of: password) }

    public var canSubmit: Bool {
        !isBusy && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && policy.issues(password: password, confirmation: confirmation).isEmpty
    }

    public func submit() async {
        guard canSubmit else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let unlocked = try await app.profileService.createProfile(displayName: displayName, password: password,
                                                                      confirmation: confirmation)
            password = ""
            confirmation = ""
            error = nil
            await app.didUnlock(unlocked)
        } catch {
            self.error = AuthMessages.message(for: error)
        }
    }
}
