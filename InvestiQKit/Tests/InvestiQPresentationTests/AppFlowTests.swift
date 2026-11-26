import XCTest
@testable import InvestiQPresentation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices
import InvestiQTestSupport

@MainActor
final class AppFlowTests: XCTestCase {
    var context: TestContext!
    let password = "Bezpečné heslo 123"

    override func setUp() async throws { context = try TestContext() }

    func makeApp() -> AppModel {
        AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                             biometricStore: context.biometrics,
                                             passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock))
    }

    func completeOnboarding(_ app: AppModel, age: AgeCategory = .from26to35) async {
        let vm = OnboardingViewModel(app: app, locale: Locale(identifier: "cs_CZ"))
        vm.essentialExpensesText = "25 000,50"
        XCTAssertEqual(vm.essentialExpenses, Decimal(string: "25000.5"))
        await completeOnboarding(app, using: vm, age: age)
    }

    func completeOnboarding(_ app: AppModel, using vm: OnboardingViewModel, age: AgeCategory = .from26to35) async {
        vm.next() // welcome → residence
        vm.country = "CZ"; vm.currency = .czk; vm.next()
        vm.ageCategory = age; vm.next()
        vm.knowledgeLevel = .beginner; vm.experience = .savingsOnly; vm.next()
        vm.goals = [.learning]; vm.horizon = .overTenYears; vm.next()
        vm.incomeStability = .stable; vm.emergencyFund = .threeToSixMonths; vm.debtStatus = .noDebt
        vm.next()
        vm.riskAttitude = .balanced; vm.next()
        XCTAssertEqual(vm.step, .summary)
        XCTAssertTrue(vm.canAdvance)
        await vm.finish()
    }

    func testFirstLaunchCreateOnboardLockUnlock() async throws {
        let app = makeApp()
        await app.bootstrap()
        XCTAssertEqual(app.state, .welcome)

        let create = CreateProfileViewModel(app: app)
        create.displayName = "Moje"
        create.password = password
        XCTAssertFalse(create.canSubmit) // confirmation missing
        create.confirmation = password
        XCTAssertTrue(create.canSubmit)
        await create.submit()
        XCTAssertEqual(app.state, .onboarding)
        XCTAssertEqual(create.password, "", "password must be cleared")

        await completeOnboarding(app)
        XCTAssertEqual(app.state, .unlocked)
        XCTAssertTrue(app.preferences.onboardingCompleted)
        XCTAssertFalse(app.educationalMode)

        await app.lock(reason: .manual)
        XCTAssertEqual(app.state, .locked)
        XCTAssertNil(app.session)

        let lock = LockScreenViewModel(app: app)
        await lock.onAppear()
        lock.password = "wrong password!"
        await lock.unlock()
        XCTAssertEqual(lock.error, Message("auth.error.wrongPasswordRemaining", [.integer(4)]))
        lock.password = password
        await lock.unlock()
        XCTAssertEqual(app.state, .unlocked, "onboarding is not repeated after unlock")
    }

    func testLanguageChosenAtStartOfOnboardingIsKept() async throws {
        let app = makeApp()
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "Jazyk"
        create.password = password
        create.confirmation = password
        await create.submit()
        XCTAssertEqual(app.state, .onboarding)

        let vm = OnboardingViewModel(app: app, locale: Locale(identifier: "cs_CZ"))
        XCTAssertEqual(vm.step, .welcome)
        XCTAssertNil(vm.languageOverride, "system language until the user picks one")
        await vm.setLanguage("en")
        XCTAssertEqual(app.preferences.languageOverride, "en")
        await vm.setLanguage("de")
        XCTAssertEqual(app.preferences.languageOverride, "en", "unsupported languages are ignored")

        // Amounts are read in the language shown on screen.
        vm.essentialExpensesText = "25,000.50"
        XCTAssertEqual(vm.essentialExpenses, Decimal(string: "25000.5"))
        vm.essentialExpensesText = ""

        await completeOnboarding(app, using: vm)
        XCTAssertEqual(app.state, .unlocked)
        XCTAssertEqual(app.preferences.languageOverride, "en", "finishing onboarding keeps the language")

        await app.lock(reason: .manual)
        let lock = LockScreenViewModel(app: app)
        await lock.onAppear()
        lock.password = password
        await lock.unlock()
        XCTAssertEqual(app.preferences.languageOverride, "en", "stored in the encrypted profile")
    }

    func testMinorGetsEducationalMode() async throws {
        let app = makeApp()
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "Student"; create.password = password; create.confirmation = password
        await create.submit()
        await completeOnboarding(app, age: .under18)
        XCTAssertTrue(app.educationalMode)
        let profiles = try await app.profileService.profiles()
        XCTAssertEqual(profiles.first?.educationalMode, true)
    }

    func testMinorSeesNoBrokerWebsitesButKeepsRegisters() async throws {
        let app = makeApp()
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "Student"; create.password = password; create.confirmation = password
        await create.submit()
        await completeOnboarding(app, age: .under18)
        let brokers = BrokersViewModel(app: app)
        brokers.load()
        XCTAssertFalse(brokers.brokers.isEmpty)
        XCTAssertTrue(brokers.brokers.allSatisfy { brokers.websiteURL($0) == nil }, "no sign-up paths for minors")
        XCTAssertTrue(brokers.brokers.allSatisfy { $0.registerURL.host?.isEmpty == false }, "supervisors' registers stay available")
    }

    func testAutoLockAfterInactivity() async throws {
        let app = makeApp()
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "P"; create.password = password; create.confirmation = password
        await create.submit()
        await completeOnboarding(app)
        context.clock.advance(by: 4 * 60)
        await app.checkAutoLock()
        XCTAssertEqual(app.state, .unlocked)
        app.registerActivity()
        context.clock.advance(by: 5 * 60)
        await app.checkAutoLock()
        XCTAssertEqual(app.state, .locked)
        XCTAssertEqual(app.lastLockReason, .inactivity)
    }

    func testDemoSessionIsInMemoryAndSeparate() async throws {
        let app = makeApp()
        await app.bootstrap()
        await app.startDemo()
        XCTAssertEqual(app.state, .unlocked)
        XCTAssertTrue(app.isDemo)
        await app.lock(reason: .manual)
        XCTAssertEqual(app.state, .welcome, "demo must not create a profile")
        let contents = try FileManager.default.contentsOfDirectory(atPath: context.directory.url.path)
        XCTAssertTrue(contents.isEmpty, "demo must not write files: \(contents)")
    }

    func testSecuritySettingsChangePasswordAndDelete() async throws {
        let app = makeApp()
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "P"; create.password = password; create.confirmation = password
        await create.submit()
        await completeOnboarding(app)

        let settings = SecuritySettingsViewModel(app: app)
        await settings.load()
        await settings.setAutoLock(minutes: 15)
        XCTAssertEqual(app.preferences.autoLockMinutes, 15)
        await settings.setAutoLock(minutes: 7) // not an allowed choice
        XCTAssertEqual(app.preferences.autoLockMinutes, 15)

        await settings.setBiometricUnlock(true)
        XCTAssertTrue(settings.biometricEnabled)

        let newPassword = "Další dlouhé heslo 9"
        settings.currentPassword = password
        settings.newPassword = newPassword
        settings.newPasswordConfirmation = newPassword
        await settings.changePassword()
        XCTAssertEqual(settings.message, Message("settings.security.passwordChanged"))

        settings.deletionPassword = "wrong password!"
        await settings.deleteProfile()
        XCTAssertEqual(app.state, .unlocked, "wrong password must not delete or lock")
        settings.deletionPassword = newPassword
        await settings.deleteProfile()
        XCTAssertEqual(app.state, .welcome)
    }
}
