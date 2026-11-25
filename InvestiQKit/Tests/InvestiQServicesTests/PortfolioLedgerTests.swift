import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQTestSupport

/// Financial calculation tests for the ledger (docs/FINANCIAL_METHODOLOGY.md §1).
/// Every expected value is computed by hand in the comments.
final class PortfolioLedgerTests: XCTestCase {
    let portfolio = PortfolioID()
    let stock = InstrumentID()
    let bond = InstrumentID()
    var sequence = 0

    func tx(_ type: TransactionType, _ date: String, instrument: InstrumentID? = nil, quantity: Decimal? = nil, price: Decimal? = nil,
            amount: Decimal? = nil, currency: CurrencyCode = .czk, fees: Decimal = 0, feeCurrency: CurrencyCode? = nil, tax: Decimal = 0,
            fx: Decimal? = nil, counter: CurrencyCode? = nil, counterAmount: Decimal? = nil, split: (Int, Int)? = nil,
            accrued: Decimal? = nil) -> Transaction {
        sequence += 1
        return Transaction(portfolioID: portfolio, type: type, instrumentID: instrument, tradeDate: .d(date), quantity: quantity,
                           price: price, amount: amount, currency: currency, fees: fees, feeCurrency: feeCurrency, taxWithheld: tax,
                           accruedInterest: accrued, fxRateToBase: fx, counterCurrency: counter, counterAmount: counterAmount,
                           splitNumerator: split?.0, splitDenominator: split?.1, createdAt: fixedNow.addingTimeInterval(Double(sequence)))
    }

    func position(_ result: LedgerResult, currency: CurrencyCode = .czk) throws -> PositionState {
        try XCTUnwrap(result.positions[PositionKey(instrumentID: stock, currency: currency)])
    }

    func testBuyCapitalisesFeesIntoCostBasis() throws {
        // 10 @ 100 + fee 15 → cost 1 015, average 101.5, cash −1 015.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, fees: 15)])
        let p = try position(result)
        XCTAssertEqual(p.quantity, 10)
        XCTAssertEqual(p.costBasis, 1_015)
        XCTAssertEqual(p.averageCost, Decimal(string: "101.5"))
        XCTAssertEqual(result.cash[.czk], -1_015)
        XCTAssertFalse(result.tracksCash)
    }

    func testPartialSalesUseAverageCost() throws {
        // Buy 10 @ 100 (fee 10) → cost 1 010; buy 10 @ 120 (fee 10) → cost 2 220, avg 111.
        // Sell 5 @ 130 (fee 5): proceeds 645, cost sold 555 → realised 90; remaining cost 1 665 (avg still 111).
        // Sell 15 @ 90 (fee 5): proceeds 1 345, cost sold 1 665 → realised −320; total realised −230.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, fees: 10),
            tx(.buy, "2024-02-10", instrument: stock, quantity: 10, price: 120, fees: 10),
            tx(.sell, "2024-03-10", instrument: stock, quantity: 5, price: 130, fees: 5),
        ])
        var p = try position(result)
        XCTAssertEqual(p.realized, 90)
        XCTAssertEqual(p.costBasis, 1_665)
        XCTAssertEqual(p.averageCost, 111)
        XCTAssertEqual(p.quantity, 15)

        let closed = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, fees: 10),
            tx(.buy, "2024-02-10", instrument: stock, quantity: 10, price: 120, fees: 10),
            tx(.sell, "2024-03-10", instrument: stock, quantity: 5, price: 130, fees: 5),
            tx(.sell, "2024-04-10", instrument: stock, quantity: 15, price: 90, fees: 5),
        ])
        p = try position(closed)
        XCTAssertEqual(p.realized, -230)
        XCTAssertEqual(p.quantity, 0)
        XCTAssertEqual(p.costBasis, 0, "a closed position keeps no residual cost")
        XCTAssertNil(p.averageCost)
        XCTAssertEqual(p.tradingFees, 30)
        // Cash: −1 010 − 1 210 + 645 + 1 345 = −230 (no deposits recorded).
        XCTAssertEqual(closed.cash[.czk], -230)
    }

    func testOversellIsRejected() {
        XCTAssertThrowsError(try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100),
            tx(.sell, "2024-01-11", instrument: stock, quantity: 11, price: 100),
        ])) { error in
            guard case LedgerError.insufficientQuantity(_, let available, let requested) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(available, 10)
            XCTAssertEqual(requested, 11)
        }
        XCTAssertThrowsError(try PortfolioLedger(baseCurrency: .czk).replay([tx(.sell, "2024-01-11", instrument: stock, quantity: 1, price: 1)]))
    }

    func testSplitScalesQuantityNotCost() throws {
        // Buy 10 @ 400 → cost 4 000; 4:1 split → 40 shares, avg 100; sell 20 @ 110 → realised 2 200 − 2 000 = 200.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 400),
            tx(.split, "2024-06-01", instrument: stock, split: (4, 1)),
            tx(.sell, "2024-07-01", instrument: stock, quantity: 20, price: 110),
        ])
        let p = try position(result)
        XCTAssertEqual(p.quantity, 20)
        XCTAssertEqual(p.realized, 200)
        XCTAssertEqual(p.averageCost, 100)

        // Reverse split 1:10 → 100 shares become 10, average ×10.
        let reverse = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 100, price: 2),
            tx(.split, "2024-06-01", instrument: stock, split: (1, 10)),
        ])
        XCTAssertEqual(try position(reverse).quantity, 10)
        XCTAssertEqual(try position(reverse).averageCost, 20)
    }

    func testSameDaySplitIsAppliedBeforeTrades() throws {
        // Split and buy on the same day: the split applies to the shares held *before* that day only.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 1, price: 400),
            tx(.buy, "2024-06-01", instrument: stock, quantity: 4, price: 100),
            tx(.split, "2024-06-01", instrument: stock, split: (4, 1)),
        ])
        XCTAssertEqual(try position(result).quantity, 8)
    }

    func testDividendsWithWithholdingTax() throws {
        // Dividend 100 gross, 15 withheld → cash +85, dividends 100, tax 15.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.deposit, "2024-01-01", amount: 2_000),
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100),
            tx(.dividend, "2024-05-10", instrument: stock, amount: 100, tax: 15),
        ])
        let p = try position(result)
        XCTAssertEqual(p.dividends, 100)
        XCTAssertEqual(p.taxWithheld, 15)
        XCTAssertEqual(result.cash[.czk], 2_000 - 1_000 + 85)
        XCTAssertEqual(result.netContributionsBase, 2_000, "income is never a contribution")
        XCTAssertTrue(result.tracksCash)
    }

    func testForeignCurrencyPurchaseTracksBaseCostAtHistoricalRate() throws {
        // Base CZK. Buy 10 @ 100 USD + 1 USD fee at 23 CZK/USD → cost 1 001 USD = 23 023 CZK.
        // Sell 10 @ 100 USD + 1 USD fee at 25 CZK/USD → proceeds 999 USD = 24 975 CZK.
        // Realised USD: 999 − 1 001 = −2; realised CZK: 24 975 − 23 023 = 1 952 (FX gain despite a USD loss).
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, currency: .usd, fees: 1, fx: 23),
            tx(.sell, "2024-06-10", instrument: stock, quantity: 10, price: 100, currency: .usd, fees: 1, fx: 25),
        ])
        let p = try position(result, currency: .usd)
        XCTAssertEqual(p.realized, -2)
        XCTAssertEqual(p.realizedBase, 1_952)
        XCTAssertEqual(result.cash[.usd], -2)
    }

    func testFeeChargedInBaseCurrency() throws {
        // Buy 10 @ 100 USD at 23 CZK/USD with a 50 CZK fee: USD cost 1 000; CZK cost 23 000 + 50 = 23 050.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, currency: .usd, fees: 50, feeCurrency: .czk, fx: 23),
        ])
        let p = try position(result, currency: .usd)
        XCTAssertEqual(p.costBasis, 1_000)
        XCTAssertEqual(p.costBasisBase, 23_050)
        XCTAssertEqual(result.cash[.czk], -50)
        XCTAssertEqual(result.cash[.usd], -1_000)
    }

    func testMissingExchangeRateMakesBaseFiguresUnknownNotZero() throws {
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, currency: .usd),
        ])
        let p = try position(result, currency: .usd)
        XCTAssertNil(p.costBasisBase)
        XCTAssertEqual(p.costBasis, 1_000)
        XCTAssertTrue(result.warnings.contains(.missingExchangeRate(.usd, .d("2024-01-10"))))
    }

    func testFXConversionMovesCashAndChargesFee() throws {
        // Convert 23 000 CZK → 1 000 USD with a 100 CZK fee.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.deposit, "2024-01-01", amount: 30_000),
            tx(.fxConversion, "2024-01-02", amount: 23_000, fees: 100, counter: .usd, counterAmount: 1_000),
        ])
        XCTAssertEqual(result.cash[.czk], 30_000 - 23_100)
        XCTAssertEqual(result.cash[.usd], 1_000)
        XCTAssertEqual(result.fxConversionFeesBase, 100)
        XCTAssertEqual(result.netContributionsBase, 30_000, "conversion is not an external flow")
        XCTAssertEqual(result.flows.map(\.inflow), [30_000])
    }

    func testCouponsAndAccruedInterestOnBonds() throws {
        // Buy 5 bonds @ 1 010 with 20 accrued interest paid; coupon 225 gross (no tax); redemption @ 1 000.
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.deposit, "2024-01-01", amount: 6_000),
            tx(.buy, "2024-01-10", instrument: bond, quantity: 5, price: 1_010, accrued: 20),
            tx(.coupon, "2024-11-11", instrument: bond, amount: 225),
            tx(.bondRedemption, "2025-11-11", instrument: bond, quantity: 5, price: 1_000),
        ])
        let p = try XCTUnwrap(result.positions[PositionKey(instrumentID: bond, currency: .czk)])
        XCTAssertEqual(p.coupons, 225)
        XCTAssertEqual(p.accruedInterestPaid, 20)
        XCTAssertEqual(p.realized, -50) // 5 000 − 5 050
        XCTAssertEqual(p.quantity, 0)
        // Cash: 6 000 − 5 050 − 20 + 225 + 5 000 = 6 155.
        XCTAssertEqual(result.cash[.czk], 6_155)
    }

    func testNegativeCashWarningWhenDepositsTracked() throws {
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.deposit, "2024-01-01", amount: 500),
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100),
        ])
        XCTAssertTrue(result.warnings.contains(.negativeCash(.czk, .d("2024-01-10"))))
    }

    func testInferredFlowsWithoutDeposits() throws {
        // Without deposits, purchases are inflows and sale proceeds/income are outflows (for TWR/XIRR).
        let result = try PortfolioLedger(baseCurrency: .czk).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100, fees: 10),
            tx(.dividend, "2024-03-10", instrument: stock, amount: 50, tax: 5),
            tx(.sell, "2024-04-10", instrument: stock, quantity: 5, price: 120, fees: 10),
        ])
        XCTAssertEqual(result.flows, [PortfolioFlow(date: .d("2024-01-10"), inflow: 1_010, outflow: 0),
                                      PortfolioFlow(date: .d("2024-03-10"), inflow: 0, outflow: 45),
                                      PortfolioFlow(date: .d("2024-04-10"), inflow: 0, outflow: 590)])
    }

    func testCutoffReplaysOnlyPastTransactions() throws {
        let transactions = [tx(.buy, "2024-01-10", instrument: stock, quantity: 10, price: 100),
                            tx(.buy, "2024-03-10", instrument: stock, quantity: 5, price: 100)]
        let early = try PortfolioLedger(baseCurrency: .czk).replay(transactions, upTo: .d("2024-02-01"))
        XCTAssertEqual(try position(early).quantity, 10)
    }

    func testInvalidTransactionsAreRejectedByTheLedger() {
        XCTAssertThrowsError(try PortfolioLedger(baseCurrency: .czk).replay([tx(.buy, "2024-01-10", instrument: stock, quantity: -1, price: 10)])) {
            guard case LedgerError.invalidTransaction = $0 else { return XCTFail("\($0)") }
        }
    }

    func testLookupUsedWhenNoStoredRate() throws {
        struct Rates: HistoricalRateLookup {
            func rate(from: CurrencyCode, to: CurrencyCode, on date: LocalDate) -> Decimal? { from == .eur && to == .czk ? 25 : nil }
        }
        let result = try PortfolioLedger(baseCurrency: .czk, rates: Rates()).replay([
            tx(.buy, "2024-01-10", instrument: stock, quantity: 2, price: 50, currency: .eur),
        ])
        XCTAssertEqual(try position(result, currency: .eur).costBasisBase, 2_500)
    }
}
