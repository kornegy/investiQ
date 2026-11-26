import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class NotificationEvaluatorTests: XCTestCase {
    func testRulesThresholdsAndLeadTimes() {
        let now = Date.utc("2026-11-25T10:00:00Z")
        var rules = NotificationRule.defaults(now: now)
        var inputs = NotificationEvaluator.Inputs(today: .d("2026-11-25"))
        let id = InstrumentID()
        inputs.priceChanges = [.init(instrumentID: id, name: "A", changeFraction: -0.062, date: .d("2026-11-25")),
                               .init(instrumentID: InstrumentID(), name: "B", changeFraction: 0.01, date: .d("2026-11-25"))]
        inputs.earnings = [.init(key: "x", name: "X", date: .d("2026-11-27")), .init(key: "y", name: "Y", date: .d("2026-12-20"))]
        inputs.coupons = [.init(key: "bond", name: "Bond", date: .d("2026-11-26"))]
        inputs.maturities = [.init(key: "bond", name: "Bond", date: .d("2026-12-20"))]
        inputs.riskChanges = [.init(portfolioName: "Main", categoryKey: "market", from: "moderate", to: "elevated", computedAt: now)]
        inputs.staleInstruments = ["A", "B"]
        inputs.failingProviders = ["finnhub"]
        let all = NotificationEvaluator.evaluate(inputs, rules: rules)
        XCTAssertEqual(all.filter { $0.kind == .priceMove }.count, 1, "only moves of at least 5 %")
        XCTAssertEqual(all.filter { $0.kind == .earningsReport }.count, 1, "only within the 2-day lead time")
        XCTAssertEqual(all.filter { $0.kind == .couponPayment }.count, 1)
        XCTAssertEqual(all.filter { $0.kind == .bondMaturity }.count, 1, "maturities are announced 30 days ahead")
        XCTAssertEqual(all.filter { $0.kind == .riskChange }.count, 1)
        XCTAssertEqual(all.filter { $0.kind == .staleData }.count, 1, "one summary, not one per instrument")
        XCTAssertEqual(all.filter { $0.kind == .providerOutage }.count, 1)
        XCTAssertEqual(Set(all.map(\.dedupKey)).count, all.count, "keys are unique")
        let price = all.first { $0.kind == .priceMove }!
        XCTAssertEqual(price.dedupKey, "price:\(id.string):2026-11-25")

        rules = rules.map { var rule = $0; rule.enabled = rule.kind != .priceMove; return rule }
        XCTAssertFalse(NotificationEvaluator.evaluate(inputs, rules: rules).contains { $0.kind == .priceMove }, "disabled rules are silent")
    }

    func testCopyKeysAreInformative() {
        var inputs = NotificationEvaluator.Inputs(today: .d("2026-11-25"))
        inputs.priceChanges = [.init(instrumentID: InstrumentID(), name: "A", changeFraction: 0.08, date: .d("2026-11-25"))]
        let keys = NotificationEvaluator.evaluate(inputs, rules: NotificationRule.defaults(now: .now)).flatMap { [$0.title.key, $0.body.key] }
        XCTAssertEqual(keys, ["notification.priceMove.title", "notification.priceMove.body"])
    }
}
