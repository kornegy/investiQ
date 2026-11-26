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

    // MARK: - Untranslated keys

    /// First segments of the keys in Localization/*.json. Visible text shaped like
    /// "onboarding.age.under18" is a key SwiftUI could not resolve and printed as-is.
    private static let keyNamespaces: Set<String> = [
        "a11y", "ai", "allocation", "analysis", "analytics", "app", "asset", "auth", "backup", "bond", "brokers",
        "calendar", "chart", "common", "dashboard", "data", "delay", "demo", "disclaimer", "educationalMode", "error",
        "etf", "export", "forecast", "import", "instrument", "learn", "legal", "link", "lock", "market", "menu",
        "metric", "news", "notification", "notifications", "onboarding", "overview", "password", "planner",
        "portfolio", "profile", "provider", "quality", "range", "risk", "rule", "safety", "scenario", "section",
        "settings", "simulator", "source", "status", "strategy", "stress", "thesis", "transaction", "validation",
        "value", "welcome",
    ]

    private func looksLikeRawKey(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let namespace = parts.first, Self.keyNamespaces.contains(String(namespace)) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private func rawKeys(in app: XCUIApplication) throws -> [String] {
        var found: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            var texts = [element.label, element.title]
            if let value = element.value as? String { texts.append(value) }
            found.append(contentsOf: texts.filter(looksLikeRawKey))
            element.children.forEach(visit)
        }
        visit(try app.snapshot())
        return Array(Set(found)).sorted()
    }

    /// Checks now and again after `settle` seconds, so content that loads asynchronously is covered too.
    private func assertNoRawKeys(_ app: XCUIApplication, on screen: String, settle: TimeInterval = 0,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try rawKeys(in: app), [], "untranslated keys on \(screen)", file: file, line: line)
        guard settle > 0 else { return }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "content settles")], timeout: settle)
        XCTAssertEqual(try rawKeys(in: app), [], "untranslated keys on \(screen)", file: file, line: line)
    }

    func testDemoModeNavigatesAllSections() throws {
        let app = launchApp()
        let demo = element(app, "welcome.tryDemo")
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "welcome screen not found. Hierarchy:\n\(app.debugDescription)")
        try assertNoRawKeys(app, on: "welcome")
        demo.click()
        for section in ["overview", "market", "portfolio", "news", "risk", "planner", "simulator", "brokers", "learn", "settings"] {
            let item = element(app, "sidebar.\(section)")
            XCTAssertTrue(item.waitForExistence(timeout: 10), "missing sidebar item \(section)")
            item.click()
            try assertNoRawKeys(app, on: section, settle: 2)
        }
    }

    /// Walks every onboarding step (choosing the second option of each question, so the profile is an
    /// adult one) and fails if any label is an unresolved key.
    func testOnboardingShowsTranslatedText() throws {
        let app = launchApp()
        createProfile(app)
        XCTAssertTrue(element(app, "onboarding.continue").waitForExistence(timeout: 20))
        var goalChosen = false
        var finished = false
        for step in 0..<12 where !finished {
            try assertNoRawKeys(app, on: "onboarding step \(step)")
            let groups = app.radioGroups
            for index in 0..<groups.count {
                let options = groups.element(boundBy: index).radioButtons
                if options.count > 1 { options.element(boundBy: 1).click() }
            }
            if !goalChosen, app.checkBoxes.count > 0 {
                app.checkBoxes.element(boundBy: 0).click()
                goalChosen = true
            }
            let finish = element(app, "onboarding.finish")
            if finish.exists {
                try assertNoRawKeys(app, on: "onboarding summary")
                XCTAssertTrue(finish.isEnabled, "cannot finish onboarding")
                finish.click()
                finished = true
            } else {
                let next = element(app, "onboarding.continue")
                XCTAssertTrue(next.isEnabled, "cannot leave onboarding step \(step). Hierarchy:\n\(app.debugDescription)")
                next.click()
            }
        }
        XCTAssertTrue(finished, "onboarding did not reach the summary step")
        XCTAssertTrue(element(app, "sidebar.overview").waitForExistence(timeout: 20))
        try assertNoRawKeys(app, on: "overview after onboarding", settle: 2)
    }

    private func createProfile(_ app: XCUIApplication) {
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
    }

    func testCreateProfileLockAndUnlock() {
        let app = launchApp()
        createProfile(app)

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
