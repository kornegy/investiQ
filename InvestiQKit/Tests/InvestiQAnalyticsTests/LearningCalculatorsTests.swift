import XCTest
@testable import InvestiQAnalytics

final class LearningCalculatorsTests: XCTestCase {
    func testInflationAndFeeDragHandChecked() throws {
        // 100 at 3 % inflation for 20 years: 100 / 1.03^20 = 55.37.
        let inflation = LearningCalculators.inflation(amount: 100, rate: 0.03, years: 20)
        XCTAssertEqual(try XCTUnwrap(inflation.last).value, 55.3676, accuracy: 1e-4)
        // 100 000 at 5 % gross with a 1 % fee for 30 years: (1.05 · 0.99)^30 = 1.0395^30 = 3.19694 vs 1.05^30 = 4.32194.
        let fees = LearningCalculators.feeDrag(amount: 100_000, grossReturn: 0.05, fee: 0.01, years: 30)
        let last = try XCTUnwrap(fees.last)
        XCTAssertEqual(last.comparison, 432_194.24, accuracy: 0.01)
        XCTAssertEqual(last.value, 319_694.24, accuracy: 0.01)
        XCTAssertTrue(LearningCalculators.feeDrag(amount: 1, grossReturn: 0.05, fee: 1, years: 1).isEmpty)
    }

    func testCurrencyAndDiversification() throws {
        // +10 % in USD, USD −10 % against CZK: 1.1 · 0.9 − 1 = −1 %.
        XCTAssertEqual(LearningCalculators.currencyAdjustedReturn(assetReturn: 0.10, currencyChange: -0.10), -0.01, accuracy: 1e-12)
        let points = LearningCalculators.diversification(volatility: 0.30, correlation: 0.25, maxHoldings: 30)
        XCTAssertEqual(points.first?.volatility ?? 0, 0.30, accuracy: 1e-12)
        // n = 4: 0.30 · √(0.25 + 0.75 · 0.25) = 0.30 · √0.4375 = 0.19843.
        XCTAssertEqual(points[3].volatility, 0.198431, accuracy: 1e-6)
        // Never below the undiversifiable floor σ·√ρ = 0.15.
        XCTAssertTrue(points.allSatisfy { $0.volatility >= 0.15 - 1e-12 })
        XCTAssertEqual(points.map(\.volatility), points.map(\.volatility).sorted(by: >))
    }
}
