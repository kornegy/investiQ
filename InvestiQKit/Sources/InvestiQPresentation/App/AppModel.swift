import Foundation
import Observation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

public enum LockReason: String, Sendable { case manual, inactivity, systemSleep, screenLocked }

/// Root application state machine (docs/ARCHITECTURE.md §3.1).
@MainActor
@Observable
public final class AppModel {
    public enum State: Equatable {
        case loading
        /// No profile exists yet.
        case welcome
        case locked
        /// Unlocked but onboarding not completed.
        case onboarding
        case unlocked
        case failed(Message)
    }

    public private(set) var state: State = .loading
    public private(set) var profiles: [ProfileSummary] = []
    public private(set) var session: ProfileSession?
    public private(set) var services: SessionServices?
    public private(set) var unlockedProfile: UnlockedProfile?
    public private(set) var preferences = UserPreferences()
    public private(set) var educationalMode = false
    public private(set) var lastLockReason: LockReason?
    public var selectedSection: AppSection = .overview

    public let environment: AppEnvironment
    public let profileService: ProfileService
    private var lastActivity: Date

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.profileService = ProfileService(paths: environment.paths, secureStore: environment.secureStore,
                                             biometricStore: environment.biometricStore,
                                             derivation: environment.passwordDerivation, clock: environment.clock)
        self.lastActivity = environment.clock.now()
    }

    public var isDemo: Bool { session?.mode == .demo }

    public func bootstrap() async {
        do {
            profiles = try await profileService.profiles()
            state = profiles.isEmpty ? .welcome : .locked
        } catch {
            state = .failed(Message("app.error.profilesUnreadable"))
        }
    }

    /// Opens the encrypted databases of a freshly unlocked/created profile.
    public func didUnlock(_ unlocked: UnlockedProfile) async {
        do {
            let session = try ProfileSession.open(unlocked, paths: environment.paths, clock: environment.clock)
            let data = ProfileDataService(session: session)
            if try await data.profile() == nil {
                try await data.saveProfile(UserProfile(id: unlocked.summary.id, displayName: unlocked.summary.displayName,
                                                       createdAt: unlocked.summary.createdAt,
                                                       educationalMode: unlocked.summary.educationalMode))
            }
            preferences = try await data.preferences()
            educationalMode = unlocked.summary.educationalMode
            self.session = session
            services = SessionServices.make(session: session, preferences: preferences, environment: environment)
            self.unlockedProfile = unlocked
            profiles = try await profileService.profiles()
            lastActivity = environment.clock.now()
            lastLockReason = nil
            state = preferences.onboardingCompleted ? .unlocked : .onboarding
        } catch {
            state = .failed(Message("app.error.databaseUnreadable"))
        }
    }

    public func startDemo() async {
        do {
            let session = try ProfileSession.demo(clock: environment.clock)
            var demoPreferences = UserPreferences(baseCurrency: .czk, onboardingCompleted: true)
            demoPreferences.autoLockMinutes = 30
            try await ProfileDataService(session: session).savePreferences(demoPreferences)
            preferences = demoPreferences
            educationalMode = false
            self.session = session
            let services = SessionServices.make(session: session, preferences: demoPreferences, environment: environment)
            try await services.instruments.seedDemoUniverse()
            let demoPortfolio = try await services.portfolios.createPortfolio(name: DemoPortfolioSeeder.portfolioName, kind: .real,
                                                                              baseCurrency: demoPreferences.baseCurrency)
            try await services.portfolios.add(DemoPortfolioSeeder.transactions(portfolioID: demoPortfolio.id,
                                                                               baseCurrency: demoPreferences.baseCurrency,
                                                                               today: environment.clock.today(), createdAt: environment.clock.now()))
            self.services = services
            unlockedProfile = nil
            lastActivity = environment.clock.now()
            state = .unlocked
        } catch {
            state = .failed(Message("app.error.demoUnavailable"))
        }
    }

    /// Locks the app and releases the session (and with it the keys).
    public func lock(reason: LockReason) async {
        if let session { await session.close() }
        session = nil
        services = nil
        unlockedProfile = nil
        lastLockReason = reason
        do { profiles = try await profileService.profiles() } catch { profiles = [] }
        state = profiles.isEmpty ? .welcome : .locked
    }

    public func completeOnboarding(with profile: FinancialProfile) async throws {
        guard let session else { return }
        let data = ProfileDataService(session: session)
        try await data.saveFinancialProfile(profile)
        var updated = preferences
        updated.onboardingCompleted = true
        updated.baseCurrency = profile.primaryCurrency
        try await data.savePreferences(updated)
        preferences = updated
        try await applyEducationalModeIfMinor(profile, data: data)
        state = .unlocked
    }

    /// Minors get educational mode; it is never switched off automatically.
    private func applyEducationalModeIfMinor(_ profile: FinancialProfile, data: ProfileDataService) async throws {
        guard profile.isMinor, let unlocked = unlockedProfile, !unlocked.summary.educationalMode else { return }
        var summary = unlocked.summary
        summary.educationalMode = true
        try await profileService.updateSummary(summary)
        if var stored = try await data.profile() {
            stored.educationalMode = true
            stored.ageCategory = profile.ageCategory
            try await data.saveProfile(stored)
        }
        educationalMode = true
    }

    /// After a restore the database content changed: reload preferences, re-apply educational mode and
    /// rebuild services.
    public func reloadAfterRestore() async throws {
        guard let session else { return }
        let data = ProfileDataService(session: session)
        preferences = try await data.preferences()
        if let profile = try await data.financialProfile() { try await applyEducationalModeIfMinor(profile, data: data) }
        reloadServices()
    }

    public func updatePreferences(_ transform: (inout UserPreferences) -> Void) async throws {
        guard let session else { return }
        var updated = preferences
        transform(&updated)
        try await ProfileDataService(session: session).savePreferences(updated)
        let providersChanged = updated.providerSettings != preferences.providerSettings
            || updated.secContactEmail != preferences.secContactEmail || updated.aiSettings != preferences.aiSettings
        preferences = updated
        if providersChanged { reloadServices() }
    }

    /// Rebuilds session services after provider settings or API keys changed.
    public func reloadServices() {
        guard let session else { return }
        services = SessionServices.make(session: session, preferences: preferences, environment: environment)
    }

    // MARK: Auto-lock

    public func registerActivity() { lastActivity = environment.clock.now() }

    /// Called periodically by the UI (e.g. every 30 s) and on wake. Demo sessions are not locked
    /// (they contain no personal data) but still respect the timer for consistency.
    public func checkAutoLock() async {
        guard state == .unlocked || state == .onboarding, !isDemo else { return }
        let elapsed = environment.clock.now().timeIntervalSince(lastActivity)
        if elapsed >= Double(preferences.autoLockMinutes * 60) { await lock(reason: .inactivity) }
    }
}

/// Sidebar sections (docs/UI_UX.md §2).
extension AppModel {
    /// Checks notification rules and delivers new notifications. Runs only while InvestiQ is open and only
    /// when the user has allowed notifications in macOS (otherwise nothing is evaluated or logged).
    @discardableResult
    public func checkNotifications() async -> Int {
        guard let services, state == .unlocked || isDemo else { return 0 }
        let delivery = environment.notificationDelivery
        guard await delivery.isAuthorized() else { return 0 }
        do {
            let pending = try await services.notifications.pendingNotifications()
            if !pending.isEmpty { await delivery.deliver(pending) }
            return pending.count
        } catch {
            return 0
        }
    }
}

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview, market, portfolio, news, risk, planner, simulator, brokers, learn, settings
    public var id: String { rawValue }
    public var titleKey: String { "section.\(rawValue)" }
}
