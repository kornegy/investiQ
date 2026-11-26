import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class SimulatorEngineTests: XCTestCase {
    func testOrderPreviewHandChecked() throws {
        // Same currency: fill 100 × (1 + 0.0005) = 100.05; value 1 000.50; commission max(1, 1.0005) = 1.00.
        let local = try XCTUnwrap(SimulatorEngine.preview(side: .buy, quantity: 10, referencePrice: 100, tradeCurrency: .czk,
                                                          baseCurrency: .czk, rateToBase: nil, fees: .standard))
        XCTAssertEqual(local.fillPrice, Decimal(string: "100.05"))
        XCTAssertEqual(local.tradeValue, Decimal(string: "1000.5"))
        XCTAssertEqual(local.commissionBase, 1)
        XCTAssertEqual(local.fxFeeBase, 0)
        XCTAssertEqual(local.spreadCostBase, Decimal(string: "0.5"))
        XCTAssertEqual(local.netCashBase, Decimal(string: "1001.5"))
        // Foreign currency at 25 CZK/USD: value 25 012.50 CZK; commission 25.01; FX fee 0.25 % = 62.53.
        let foreign = try XCTUnwrap(SimulatorEngine.preview(side: .buy, quantity: 10, referencePrice: 100, tradeCurrency: .usd,
                                                            baseCurrency: .czk, rateToBase: 25, fees: .standard))
        XCTAssertEqual(foreign.tradeValueBase, Decimal(string: "25012.5"))
        XCTAssertEqual(foreign.commissionBase, Decimal(string: "25.01"))
        XCTAssertEqual(foreign.fxFeeBase, Decimal(string: "62.53"))
        XCTAssertEqual(foreign.netCashBase, Decimal(string: "25100.04"))
        // Sell fills below the reference and costs reduce the proceeds.
        let sell = try XCTUnwrap(SimulatorEngine.preview(side: .sell, quantity: 10, referencePrice: 100, tradeCurrency: .czk,
                                                         baseCurrency: .czk, rateToBase: nil, fees: .standard))
        XCTAssertEqual(sell.fillPrice, Decimal(string: "99.95"))
        XCTAssertEqual(sell.netCashBase, Decimal(string: "998.5"))
        XCTAssertNil(SimulatorEngine.preview(side: .buy, quantity: 1, referencePrice: 100, tradeCurrency: .usd, baseCurrency: .czk,
                                             rateToBase: nil, fees: .standard), "no rate, no preview")
    }

    func testFeeModelRoundTripsExactly() throws {
        let data = try JSONEncoder().encode(FeeModel.standard)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"0.0025\""))
        XCTAssertEqual(try JSONDecoder().decode(FeeModel.self, from: data), .standard)
    }

    func series(_ key: String, start: LocalDate, days: Int, price: (Int) -> Double, currency: CurrencyCode = .czk) -> PriceSeries {
        var bars: [PriceBar] = []
        var date = start
        for index in 0..<days {
            while date.isWeekend { date = date.adding(days: 1) }
            bars.append(PriceBar(date: date, close: Decimal(finite: price(index))!))
            date = date.adding(days: 1)
        }
        return PriceSeries(listing: ListingKey(mic: nil, ticker: Ticker(rawValue: key)!), currency: currency, adjustment: .split, bars: bars)
    }

    func testBacktestWithoutCostsOnFlatPricesKeepsContributions() throws {
        let start = LocalDate.d("2024-01-02")
        let a = StrategyBacktest.Asset(key: "A", name: "A", targetWeight: 0.6, series: series("A", start: start, days: 300) { _ in 50 })
        let b = StrategyBacktest.Asset(key: "B", name: "B", targetWeight: 0.4, series: series("B", start: start, days: 300) { _ in 20 })
        let free = FeeModel(fixed: 0, percent: 0, minimum: 0, spread: 0, fxFee: 0)
        let result = try StrategyBacktest(assets: [a, b], baseCurrency: .czk, fees: free, rebalancing: .quarterly, rate: { _, _ in nil })
            .run(initial: 10_000, monthly: 500, from: start, to: .d("2024-12-31"))
        XCTAssertEqual(result.contributed, 10_000 + 11 * 500)
        XCTAssertEqual(result.finalValue, result.contributed, accuracy: 1e-6)
        XCTAssertEqual(result.timeWeightedReturn ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(result.rebalances, 3, "April, July and October")
        XCTAssertEqual(result.finalWeights["A"] ?? 0, 0.6, accuracy: 1e-9)

        let costly = try StrategyBacktest(assets: [a, b], baseCurrency: .czk, fees: .standard, rebalancing: .never, rate: { _, _ in nil })
            .run(initial: 10_000, monthly: 0, from: start, to: .d("2024-12-31"))
        XCTAssertLessThan(costly.finalValue, 10_000)
        XCTAssertEqual(costly.finalValue + costly.costs, 10_000, accuracy: 1e-6, "value lost exactly equals costs on flat prices")
    }

    func testBacktestNeverUsesLaterData() throws {
        let start = LocalDate.d("2023-01-02")
        let cut = LocalDate.d("2023-06-30")
        let original = series("A", start: start, days: 400) { 100 + Double($0) * 0.1 }
        var altered = original
        altered.bars = original.bars.map { $0.date > cut ? PriceBar(date: $0.date, close: $0.close * 3) : $0 }
        func run(_ s: PriceSeries) throws -> StrategyBacktest.Result {
            try StrategyBacktest(assets: [.init(key: "A", name: "A", targetWeight: 1, series: s)], baseCurrency: .czk, fees: .standard,
                                 rebalancing: .threshold, rate: { _, _ in nil })
                .run(initial: 1_000, monthly: 100, from: start, to: .d("2024-03-01"))
        }
        let first = try run(original), second = try run(altered)
        let before1 = first.points.filter { $0.date <= cut }, before2 = second.points.filter { $0.date <= cut }
        XCTAssertEqual(before1, before2, "changing data after a date never changes results up to that date")
        XCTAssertNotEqual(first.finalValue, second.finalValue)
    }

    func testInsightsFlagPatterns() {
        let start = LocalDate.d("2025-01-02"), end = LocalDate.d("2025-03-31")
        let trades = (0..<30).map { i in
            SimulatorTrade(date: start.adding(days: i * 2), side: i % 2 == 0 ? .buy : .sell, instrumentKey: "X", valueBase: 50_000, costsBase: 100)
        }
        let falling = series("X", start: .d("2024-12-01"), days: 120) { 100 - Double($0) * 0.5 }
        let insights = SimulatorReview.insights(trades: trades, startingCapital: 100_000, start: start, end: end, averageValueBase: 100_000,
                                                weights: [("X", 0.9)], cashShare: 0.05, histories: ["X": falling])
        XCTAssertTrue(insights.contains { if case .highTurnover = $0 { return true }; return false })
        XCTAssertTrue(insights.contains { if case .frequentTrading = $0 { return true }; return false })
        XCTAssertTrue(insights.contains { if case .highFees = $0 { return true }; return false })
        XCTAssertTrue(insights.contains(.concentration(name: "X", weight: 0.9)))
        XCTAssertTrue(insights.contains { if case .sellingAfterFall(let n) = $0 { return n > 0 }; return false })
        XCTAssertTrue(SimulatorReview.insights(trades: [], startingCapital: 100_000, start: start, end: end, averageValueBase: nil,
                                               weights: [], cashShare: nil, histories: [:]).isEmpty)
    }
}
