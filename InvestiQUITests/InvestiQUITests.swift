import XCTest

/// UI tests run with `--ui-testing`: a throwaway data directory and an in-memory keychain, so they
/// never touch real user data (see AppDependencies.makeUITestingEnvironment).
final class InvestiQUITests: XCTestCase {
    private let password = "Correct horse 2026!"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        // On CI runners the initial window is sometimes not created; open one explicitly (File ▸ New Window).
        if !app.windows.firstMatch.waitForExistence(timeout: 10) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "no window. Hierarchy:\n\(app.debugDescription)")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testDemoModeNavigatesAllSections() {
        let app = launchApp()
        let demo = element(app, "welcome.tryDemo")
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "welcome screen not found. Hierarchy:\n\(app.debugDescription)")
        demo.click()
        for section in ["overview", "market", "portfolio", "news", "risk", "planner", "simulator", "brokers", "learn", "settings"] {
            let item = element(app, "sidebar.\(section)")
            XCTAssertTrue(item.waitForExistence(timeout: 10), "missing sidebar item \(section)")
            item.click()
        }
    }

    func testCreateProfileLockAndUnlock() {
        let app = launchApp()
        let create = element(app, "welcome.createProfile")
        XCTAssertTrue(create.waitForExistence(timeout: 30), "welcome screen not found. Hierarchy:\n\(app.debugDescription)")
        create.click()

        let name = element(app, "profile.displayName")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("UI Test")
        let passwordField = element(app, "profile.password")
        passwordField.click()
        passwordField.typeText(password)
        let confirmation = element(app, "profile.passwordConfirmation")
        confirmation.click()
        confirmation.typeText(password)
        element(app, "profile.create.submit").click()

        XCTAssertTrue(element(app, "onboarding.continue").waitForExistence(timeout: 20))
        app.typeKey("l", modifierFlags: .command)

        let lockPassword = element(app, "lock.password")
        XCTAssertTrue(lockPassword.waitForExistence(timeout: 10))
        lockPassword.click()
        lockPassword.typeText(password)
        element(app, "lock.unlock").click()
        XCTAssertTrue(element(app, "onboarding.continue").waitForExistence(timeout: 20))
    }
}
