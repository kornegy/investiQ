import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQTestSupport

final class PortfolioValuationTests: XCTestCase {
    let portfolio = PortfolioID()
    let stock = InstrumentID()
    var sequence = 0

    func tx(_ type: TransactionType, _ date: String, quantity: Decimal? = nil, price: Decimal? = nil, amount: Decimal? = nil,
            currency: CurrencyCode = .czk, fx: Decimal? = nil, split: (Int, Int)? = nil) -> Transaction {
        sequence += 1
        return Transaction(portfolioID: portfolio, type: type, instrumentID: type == .deposit ? nil : stock, tradeDate: .d(date),
                           quantity: quantity, price: price, amount: amount, currency: currency, fxRateToBase: fx,
                           splitNumerator: split?.0, splitDenominator: split?.1, createdAt: fixedNow.addingTimeInterval(Double(sequence)))
    }

    func sourced(_ value: Decimal) -> Sourced<Decimal> {
        Sourced(value, metadata: DataMetadata(source: .demo, retrievedAt: fixedNow, delay: .endOfDay, quality: .validated))
    }

    func testUnrealisedSplitsIntoPriceAndFXEffect() throws {
        // Buy 10 @ 100 USD at 23 CZK/USD → cost 23 000 CZK. Now 110 USD at 25 CZK/USD → value 27 500 CZK.
        // Unrealised 4 500 = price effect (110−100)×10×25 = 2 500 + FX effect 1 000×25 − 23 000 = 2 000.
        let ledger = try PortfolioLedger(baseCurrency: .czk).replay([tx(.buy, "2024-01-10", quantity: 10, price: 100, currency: .usd, fx: 23)])
        let key = PositionKey(instrumentID: stock, currency: .usd)
        let valuation = PortfolioValuer.value(ledger, inputs: ValuationInputs(prices: [key: sourced(110)], fxToBase: [.usd: sourced(25)]))
        let holding = try XCTUnwrap(valuation.holdings.first)
        XCTAssertEqual(holding.marketValueBase, 27_500)
        XCTAssertEqual(holding.unrealizedBase, 4_500)
        XCTAssertEqual(holding.priceEffectBase, 2_500)
        XCTAssertEqual(holding.fxEffectBase, 2_000)
        XCTAssertEqual(valuation.totalValueBase, 27_500, "without recorded deposits, negative cash is not netted against holdings")
        XCTAssertEqual(valuation.returnBasis, .totalPurchases)
        XCTAssertEqual(valuation.totalReturnFraction!, 4_500.0 / 23_000.0, accuracy: 1e-12)
        XCTAssertEqual(holding.weight!, 1, accuracy: 1e-12)
    }

    func testMissingPriceOrRateMakesTotalUnknown() throws {
        let ledger = try PortfolioLedger(baseCurrency: .czk).replay([tx(.buy, "2024-01-10", quantity: 10, price: 100, currency: .usd, fx: 23)])
        let key = PositionKey(instrumentID: stock, currency: .usd)
        let noPrice = PortfolioValuer.value(ledger, inputs: ValuationInputs(fxToBase: [.usd: sourced(25)]))
        XCTAssertNil(noPrice.totalValueBase)
        XCTAssertEqual(noPrice.missingPrices, [key])
        let noRate = PortfolioValuer.value(ledger, inputs: ValuationInputs(prices: [key: sourced(110)]))
        XCTAssertNil(noRate.totalValueBase)
        XCTAssertEqual(noRate.missingRates, [.usd])
    }

    func testDepositsAreNotProfitAndCashIsValued() throws {
        // Deposit 2 000, buy 10 @ 100, price now 120 → holdings 1 200 + cash 1 000 = 2 200; return 200 on 2 000 = 10 %.
        let ledger = try PortfolioLedger(baseCurrency: .czk).replay([tx(.deposit, "2024-01-01", amount: 2_000),
                                                                     tx(.buy, "2024-01-10", quantity: 10, price: 100)])
        let key = PositionKey(instrumentID: stock, currency: .czk)
        let valuation = PortfolioValuer.value(ledger, inputs: ValuationInputs(prices: [key: sourced(120)]))
        XCTAssertEqual(valuation.totalValueBase, 2_200)
        XCTAssertEqual(valuation.cashBase, 1_000)
        XCTAssertEqual(valuation.totalReturnBase, 200)
        XCTAssertEqual(valuation.totalReturnFraction!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(valuation.returnBasis, .netContributions)
    }

    func seriesFor(_ closes: [(String, Decimal)], adjustment: PriceAdjustment) -> PriceSeries {
        PriceSeries(listing: ListingKey(mic: nil, ticker: Ticker(rawValue: "S")!), currency: .czk, adjustment: adjustment,
                    bars: closes.map { PriceBar(date: .d($0.0), close: $0.1) })
    }

    func testValueSeriesIsContinuousAcrossSplitsForAdjustedAndRawPrices() {
        // Buy 10 @ 400; 4:1 split on 2024-01-12. True value stays 4 000 on all days.
        let transactions = [tx(.buy, "2024-01-10", quantity: 10, price: 400), tx(.split, "2024-01-12", split: (4, 1))]
        let dates: [LocalDate] = [.d("2024-01-10"), .d("2024-01-11"), .d("2024-01-12")]
        let key = PositionKey(instrumentID: stock, currency: .czk)
        let adjusted = seriesFor([("2024-01-10", 100), ("2024-01-11", 100), ("2024-01-12", 100)], adjustment: .split)
        let raw = seriesFor([("2024-01-10", 400), ("2024-01-11", 400), ("2024-01-12", 100)], adjustment: .unadjusted)
        for series in [adjusted, raw] {
            let points = ValueSeriesBuilder.build(transactions: transactions, baseCurrency: .czk, dates: dates, prices: [key: series], fx: { _, _ in nil })
            XCTAssertEqual(points.map(\.value), [4_000, 4_000, 4_000], "\(series.adjustment)")
        }
    }

    func testValueSeriesMarksMissingPricesAndComputesTWRandXIRR() throws {
        // Buy 10 @ 100 on day 1; prices 100 → 110 → 121 → TWR 21 %.
        let transactions = [tx(.buy, "2024-01-01", quantity: 10, price: 100)]
        let key = PositionKey(instrumentID: stock, currency: .czk)
        let series = seriesFor([("2024-01-01", 100), ("2024-07-01", 110), ("2025-01-01", 121)], adjustment: .split)
        let points = ValueSeriesBuilder.build(transactions: transactions, baseCurrency: .czk,
                                              dates: [.d("2024-01-01"), .d("2024-07-01"), .d("2025-01-01")], prices: [key: series], fx: { _, _ in nil })
        XCTAssertEqual(points.map(\.value), [1_000, 1_100, 1_210])
        XCTAssertEqual(try XCTUnwrap(ValueSeriesBuilder.timeWeightedReturn(points)), 0.21, accuracy: 1e-12)
        let ledger = try PortfolioLedger(baseCurrency: .czk).replay(transactions)
        // 1 000 → 1 210 over 366 days (2024 is a leap year): (1.21)^(365/366) − 1.
        let xirr = try XCTUnwrap(ValueSeriesBuilder.moneyWeightedReturn(flows: ledger.flows, terminalValue: 1_210, terminalDate: .d("2025-01-01")))
        XCTAssertEqual(xirr, pow(1.21, 365.0 / 366.0) - 1, accuracy: 1e-9)

        let gap = ValueSeriesBuilder.build(transactions: transactions, baseCurrency: .czk, dates: [.d("2024-03-01")],
                                           prices: [key: seriesFor([("2024-01-01", 100)], adjustment: .split)], fx: { _, _ in nil })
        XCTAssertNil(gap.first?.value, "prices older than the carry window are not used")
    }
}
