import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class PerformanceTests: XCTestCase {
    func series(_ closes: [Decimal], start: String = "2020-01-01") -> PriceSeries {
        let first = LocalDate.d(start)
        return PriceSeries(listing: ListingKey(mic: nil, ticker: Ticker(rawValue: "T")!), currency: .usd, adjustment: .split,
                           bars: closes.enumerated().map { PriceBar(date: first.adding(days: $0.offset), close: $0.element) })
    }

    func testStatistics() {
        XCTAssertEqual(Statistics.mean([1, 2, 3, 4]), 2.5)
        // Sample stdev of 2,4,4,4,5,5,7,9 = sqrt(32/7) = 2.138089935...
        XCTAssertEqual(Statistics.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9])!, 2.1380899353, accuracy: 1e-9)
        XCTAssertEqual(Statistics.quantile([1, 2, 3, 4, 5], 0.25), 2)
        XCTAssertEqual(Statistics.quantile([10, 20], 0.5), 15)
        XCTAssertEqual(Statistics.correlation([1, 2, 3], [2, 4, 6])!, 1, accuracy: 1e-12)
        XCTAssertEqual(Statistics.correlation([1, 2, 3], [3, 2, 1])!, -1, accuracy: 1e-12)
        XCTAssertNil(Statistics.correlation([1, 1, 1], [1, 2, 3]), "zero variance → undefined, not 0")
        XCTAssertNil(Statistics.standardDeviation([1]))
    }

    func testMaximumDrawdownWithRecovery() throws {
        // Peak 120 on day 2, trough 90 on day 4 → 25 % drawdown; recovered on day 6 (125 ≥ 120).
        let dd = try XCTUnwrap(Performance.maximumDrawdown(series([100, 110, 120, 100, 90, 115, 125])))
        XCTAssertEqual(dd.depth, 0.25, accuracy: 1e-12)
        XCTAssertEqual(dd.peak, .d("2020-01-03"))
        XCTAssertEqual(dd.trough, .d("2020-01-05"))
        XCTAssertEqual(dd.recovery, .d("2020-01-07"))
        let rising = try XCTUnwrap(Performance.maximumDrawdown(series([1, 2, 3])))
        XCTAssertEqual(rising.depth, 0)
    }

    func testCAGRIsNotAnnualisedForShortPeriods() {
        XCTAssertNil(Performance.cagr(series([100, 110])))
        let twoYears = PriceSeries(listing: ListingKey(mic: nil, ticker: Ticker(rawValue: "T")!), currency: .usd, adjustment: .split, bars: [
            PriceBar(date: .d("2020-01-01"), close: 100), PriceBar(date: .d("2022-01-01"), close: 121),
        ])
        // (1.21)^(365.25/731) − 1 ≈ 0.09993
        XCTAssertEqual(Performance.cagr(twoYears)!, 0.0999, accuracy: 0.0005)
        XCTAssertEqual(Performance.totalReturn(twoYears)!, 0.21, accuracy: 1e-12)
    }

    func testVolatilityNeedsSixtyReturnsAndMatchesHandComputation() {
        XCTAssertNil(Performance.annualizedVolatility(series(Array(repeating: 100, count: 30))))
        // Alternating ±1 % moves: log returns ln(1.01) and ln(1/1.01) = ±0.00995033…
        var closes: [Decimal] = [100]
        for i in 0..<120 { closes.append(i % 2 == 0 ? 101 : 100) }
        let vol = Performance.annualizedVolatility(series(closes))!
        let r = log(1.01)
        // Sample stdev of 120 values alternating ±r with mean 0: r·sqrt(120/119).
        XCTAssertEqual(vol, r * (120.0 / 119.0).squareRoot() * 252.0.squareRoot(), accuracy: 1e-9)
    }

    func testExplainableResultCarriesLimitations() {
        let sourced = Sourced(series([100, 101, 102]), metadata: DataMetadata(source: .demo, retrievedAt: fixedNow, delay: .synthetic, quality: .validated))
        let result = Performance.volatilityResult(sourced, now: fixedNow)
        XCTAssertNil(result.value)
        XCTAssertEqual(result.methodID, "M-VOL-1")
        XCTAssertLessThan(result.completeness, 0.1)
        XCTAssertTrue(result.limitations.contains(Message("analytics.limitation.tooFewObservations", [.integer(2), .integer(60)])))
    }
}
