import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

/// Forecast validation tests (spec §14, §31): look-ahead bias, baselines, calibration, scenarios.
final class ForecastValidationTests: XCTestCase {
    /// Geometric random walk with seeded normal shocks.
    func randomWalk(days: Int, drift: Double = 0, volatility: Double = 0.01, seed: UInt64 = 7, start: Double = 100) -> PriceSeries {
        var generator = SeededRandom(seed: seed)
        var price = start
        var bars: [PriceBar] = []
        let first = LocalDate.d("2015-01-01")
        for day in 0..<days {
            let u1 = max(Double.random(in: 0..<1, using: &generator), 1e-12), u2 = Double.random(in: 0..<1, using: &generator)
            let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            price *= exp(drift + volatility * z)
            bars.append(PriceBar(date: first.adding(days: day), close: Decimal(finite: (price * 10_000).rounded() / 10_000)!))
        }
        return PriceSeries(listing: ListingKey(mic: nil, ticker: Ticker(rawValue: "RW")!), currency: .usd, adjustment: .split, bars: bars)
    }

    func testNoLookAhead_futureDataNeverChangesAForecast() throws {
        let series = randomWalk(days: 800)
        let origin = series.bars[400].date
        var tampered = series
        for index in 401..<tampered.bars.count { tampered.bars[index].close *= 3 } // rewrite the future
        for model in ForecastModelID.allCases {
            let a = try Forecaster().forecast(model, history: series.asOf(origin).bars.map { $0.close.doubleValue }, originDate: origin, horizon: 21)
            let b = try Forecaster().forecast(model, history: tampered.asOf(origin).bars.map { $0.close.doubleValue }, originDate: origin, horizon: 21)
            XCTAssertEqual(a, b, "\(model) must not depend on data after the origin")
        }
    }

    func testForecastsAreReproducibleAndOrdered() throws {
        let history = randomWalk(days: 600).bars.map { $0.close.doubleValue }
        for model in ForecastModelID.allCases {
            let f = try Forecaster().forecast(model, history: history, originDate: .d("2016-08-23"), horizon: 21)
            XCTAssertEqual(f, try Forecaster().forecast(model, history: history, originDate: .d("2016-08-23"), horizon: 21))
            XCTAssertLessThanOrEqual(f.lower95, f.lower80)
            XCTAssertLessThanOrEqual(f.lower80, f.upper80)
            XCTAssertLessThanOrEqual(f.upper80, f.upper95)
        }
        XCTAssertThrowsError(try Forecaster().forecast(.drift, history: Array(history.prefix(100)), originDate: .d("2015-04-10"), horizon: 21)) {
            XCTAssertEqual($0 as? ForecastError, .insufficientHistory(available: 100, required: 252))
        }
    }

    func testModelsDoNotBeatNaiveOnARandomWalk() throws {
        let series = randomWalk(days: 252 * 6)
        let validator = WalkForwardValidator()
        let naive = try XCTUnwrap(validator.validate(.naive, series: series))
        let drift = try XCTUnwrap(validator.validate(.drift, series: series))
        XCTAssertGreaterThanOrEqual(naive.evaluations, WalkForwardValidator.minimumEvaluations)
        XCTAssertFalse(naive.isUsefulSignal, "the baseline is never presented as a signal")
        XCTAssertFalse(drift.isUsefulSignal, "on a pure random walk no model may be presented as a useful signal")
        XCTAssertEqual(drift.mase ?? 0, 1, accuracy: 0.25)
        XCTAssertEqual(drift.calibration.count, 9)
    }

    func testDriftBeatsNaiveOnAStrongTrend() throws {
        // 0.2 % daily drift with very small noise: the drift model should be clearly better than naive.
        let series = randomWalk(days: 252 * 5, drift: 0.002, volatility: 0.001)
        let metrics = try XCTUnwrap(WalkForwardValidator().validate(.drift, series: series))
        XCTAssertLessThan(try XCTUnwrap(metrics.mase), 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.directionalAccuracy), 0.9)
    }

    func testIntervalsAreRoughlyCalibratedOnIIDReturns() throws {
        let series = randomWalk(days: 252 * 10, volatility: 0.012, seed: 99)
        let metrics = try XCTUnwrap(WalkForwardValidator(horizon: 10, step: 10).validate(.bootstrap, series: series))
        XCTAssertGreaterThan(metrics.evaluations, 200)
        XCTAssertEqual(metrics.coverage80, 0.8, accuracy: 0.12)
        XCTAssertEqual(metrics.coverage95, 0.95, accuracy: 0.08)
    }

    func testInverseNormal() {
        XCTAssertEqual(WalkForwardValidator.inverseNormal(0.975), 1.959964, accuracy: 1e-5)
        XCTAssertEqual(WalkForwardValidator.inverseNormal(0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(WalkForwardValidator.inverseNormal(0.01), -2.326348, accuracy: 1e-5)
    }

    func testScenariosAreOrderedAndNeedEnoughHistory() throws {
        let history = randomWalk(days: 252 * 6, drift: 0.0003).bars.map { $0.close.doubleValue }
        let scenarios = try XCTUnwrap(ScenarioBuilder.scenarios(history: history, horizon: 252, startValue: 10_000))
        XCTAssertEqual(scenarios.map(\.kind), [.pessimistic, .base, .optimistic])
        XCTAssertLessThanOrEqual(scenarios[0].periodReturn, scenarios[1].periodReturn)
        XCTAssertLessThanOrEqual(scenarios[1].periodReturn, scenarios[2].periodReturn)
        XCTAssertNil(ScenarioBuilder.scenarios(history: Array(history.prefix(500)), horizon: 252, startValue: 10_000))
        let grid = ScenarioBuilder.sensitivity(amount: 1_000, baseAnnualReturn: 0.05)
        XCTAssertEqual(grid.count, 15)
        XCTAssertEqual(grid.first { $0.annualReturn == 0.05 && $0.years == 10 }!.endValue, 1_000 * pow(1.05, 10), accuracy: 1e-9)
    }
}
