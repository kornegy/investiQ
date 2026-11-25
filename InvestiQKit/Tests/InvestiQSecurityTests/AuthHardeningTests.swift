import XCTest
@testable import InvestiQSecurity
import InvestiQCore
import InvestiQTestSupport

final class AuthHardeningTests: XCTestCase {
    func testLockoutSchedule() {
        let policy = LoginThrottlePolicy()
        XCTAssertNil(policy.lockoutDuration(afterFailures: 4))
        XCTAssertEqual(policy.lockoutDuration(afterFailures: 5), 30)
        XCTAssertEqual(policy.lockoutDuration(afterFailures: 6), 60)
        XCTAssertEqual(policy.lockoutDuration(afterFailures: 7), 120)
        XCTAssertEqual(policy.lockoutDuration(afterFailures: 50), 900)
    }

    func testThrottlePersistsAndResets() throws {
        let store = InMemorySecureStore()
        let clock = ManualTimeProvider(fixedNow)
        let throttle = LoginThrottle(store: store, account: "p1", clock: clock)
        for _ in 0..<4 { _ = try throttle.recordFailure() }
        XCTAssertEqual(try throttle.decision(), .allowed(remainingFreeAttempts: 1))
        XCTAssertEqual(try throttle.recordFailure(), .locked(until: fixedNow.addingTimeInterval(30)))

        // A new instance (app restart) sees the same state.
        let restarted = LoginThrottle(store: store, account: "p1", clock: clock)
        XCTAssertEqual(try restarted.decision(), .locked(until: fixedNow.addingTimeInterval(30)))

        clock.advance(by: 31)
        XCTAssertEqual(try restarted.decision(), .allowed(remainingFreeAttempts: 0))
        XCTAssertEqual(try restarted.recordFailure(), .locked(until: clock.now().addingTimeInterval(60)))

        try restarted.recordSuccess()
        XCTAssertEqual(try restarted.decision(), .allowed(remainingFreeAttempts: 5))
    }

    func testClockRollbackDoesNotShortenLockout() throws {
        let store = InMemorySecureStore()
        let clock = ManualTimeProvider(fixedNow)
        let throttle = LoginThrottle(store: store, account: "p1", clock: clock)
        for _ in 0..<5 { _ = try throttle.recordFailure() }
        clock.set(fixedNow.addingTimeInterval(-3600))
        guard case .locked = try throttle.decision() else { return XCTFail("expected lockout after clock rollback") }
    }

    func testCorruptedThrottleStateFailsClosed() throws {
        let store = InMemorySecureStore()
        try store.set(Data("garbage".utf8), service: .authThrottle, account: "p1")
        let throttle = LoginThrottle(store: store, account: "p1", clock: ManualTimeProvider(fixedNow))
        guard case .locked = try throttle.decision() else { return XCTFail("corrupted state must lock") }
    }

    func testPasswordPolicy() {
        let policy = PasswordPolicy()
        XCTAssertEqual(policy.issues(password: "short", confirmation: "short"), [.tooShort])
        XCTAssertTrue(policy.issues(password: "aaaaaaaaaaaa", confirmation: "aaaaaaaaaaaa").contains(.repeatedCharacter))
        XCTAssertTrue(policy.issues(password: "password123", confirmation: "password123").contains(.commonPassword))
        XCTAssertEqual(policy.issues(password: "Long enough pass", confirmation: "Long enough pasS"), [.confirmationMismatch])
        XCTAssertEqual(policy.issues(password: " Long enough pass", confirmation: " Long enough pass"), [.surroundingWhitespace])
        XCTAssertEqual(policy.issues(password: "Velmi-Dlouhé-Heslo-2026", confirmation: "Velmi-Dlouhé-Heslo-2026"), [])
        XCTAssertEqual(policy.strength(of: "short"), .weak)
        XCTAssertEqual(policy.strength(of: "Velmi-Dlouhé-Heslo-2026"), .strong)
    }

    func testCSVSanitizerNeutralisesFormulas() {
        XCTAssertEqual(CSVSanitizer.cell("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(CSVSanitizer.cell("+cmd"), "'+cmd")
        XCTAssertEqual(CSVSanitizer.cell("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(CSVSanitizer.cell("-12.5"), "-12.5") // plain numbers stay numbers
        XCTAssertEqual(CSVSanitizer.cell("-2+3"), "'-2+3")
        XCTAssertEqual(CSVSanitizer.cell("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVSanitizer.cell("plain"), "plain")
        XCTAssertEqual(CSVSanitizer.row(["2026-01-01", "buy", "=1+1"]), "2026-01-01,buy,'=1+1")
    }

    func testRedactorRemovesSecrets() {
        let url = URL(string: "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=IBM&apikey=SECRET123")!
        let redacted = Redactor.redact(url)
        XCTAssertFalse(redacted.contains("SECRET123"))
        XCTAssertTrue(redacted.contains("apikey=REDACTED"))
        XCTAssertTrue(redacted.contains("symbol=IBM"))
        XCTAssertEqual(Redactor.redact(headers: ["X-Finnhub-Token": "abc", "Accept": "json"]),
                       ["X-Finnhub-Token": "REDACTED", "Accept": "json"])
    }
}
