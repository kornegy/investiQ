import XCTest
@testable import InvestiQCore
import InvestiQTestSupport

final class TransactionValidatorTests: XCTestCase {
    let portfolio = PortfolioID()
    let instrument = InstrumentID()

    func make(_ type: TransactionType, quantity: Decimal? = nil, price: Decimal? = nil, amount: Decimal? = nil,
              fees: Decimal = 0, tax: Decimal = 0, instrument: InstrumentID? = nil) -> Transaction {
        Transaction(portfolioID: portfolio, type: type, instrumentID: instrument, tradeDate: .d("2026-01-05"),
                    quantity: quantity, price: price, amount: amount, currency: .usd, fees: fees, taxWithheld: tax,
                    createdAt: fixedNow)
    }

    func testValidBuy() throws {
        XCTAssertNoThrow(try TransactionValidator.validate(make(.buy, quantity: 10, price: .n("150.5"), fees: 1, instrument: instrument), baseCurrency: .czk))
    }

    func testBuyRequiresInstrumentQuantityAndPrice() {
        XCTAssertThrowsError(try TransactionValidator.validate(make(.buy, quantity: 1, price: 1), baseCurrency: .czk))
        XCTAssertThrowsError(try TransactionValidator.validate(make(.buy, price: 1, instrument: instrument), baseCurrency: .czk))
        XCTAssertThrowsError(try TransactionValidator.validate(make(.buy, quantity: 0, price: 1, instrument: instrument), baseCurrency: .czk))
        XCTAssertThrowsError(try TransactionValidator.validate(make(.buy, quantity: 1, price: -1, instrument: instrument), baseCurrency: .czk))
    }

    func testNegativeFeesRejected() {
        XCTAssertThrowsError(try TransactionValidator.validate(make(.buy, quantity: 1, price: 1, fees: -1, instrument: instrument), baseCurrency: .czk)) {
            XCTAssertEqual($0 as? TransactionValidationError, .negative("fees"))
        }
    }

    func testTaxCannotExceedGrossIncome() {
        XCTAssertThrowsError(try TransactionValidator.validate(make(.dividend, amount: 10, tax: 11, instrument: instrument), baseCurrency: .czk)) {
            XCTAssertEqual($0 as? TransactionValidationError, .taxExceedsIncome)
        }
    }

    func testSplitRatio() {
        var split = make(.split, instrument: instrument)
        split.splitNumerator = 4; split.splitDenominator = 1
        XCTAssertNoThrow(try TransactionValidator.validate(split, baseCurrency: .czk))
        split.splitDenominator = 4
        XCTAssertThrowsError(try TransactionValidator.validate(split, baseCurrency: .czk))
    }

    func testFxConversionNeedsDifferentCurrency() {
        var fx = make(.fxConversion, amount: 100)
        fx.counterCurrency = .usd; fx.counterAmount = 100
        XCTAssertThrowsError(try TransactionValidator.validate(fx, baseCurrency: .czk)) {
            XCTAssertEqual($0 as? TransactionValidationError, .sameCurrencyConversion)
        }
        fx.counterCurrency = .eur; fx.counterAmount = .n("92.1")
        XCTAssertNoThrow(try TransactionValidator.validate(fx, baseCurrency: .czk))
    }

    func testFeeCurrencyMustBeTradeOrBase() {
        var buy = make(.buy, quantity: 1, price: 1, fees: 1, instrument: instrument)
        buy.feeCurrency = .czk
        XCTAssertNoThrow(try TransactionValidator.validate(buy, baseCurrency: .czk))
        buy.feeCurrency = .gbp
        XCTAssertThrowsError(try TransactionValidator.validate(buy, baseCurrency: .czk))
    }

    func testSafetyNotesFromProfile() {
        let profile = FinancialProfile(country: "CZ", primaryCurrency: .czk, ageCategory: .under18, knowledgeLevel: .advanced,
                                       goals: [.learning], horizon: .underOneYear, incomeStability: .noIncome,
                                       essentialMonthlyExpenses: nil, emergencyFund: .none, debtStatus: .highInterest,
                                       riskAttitude: .avoidLosses, experience: .none, updatedAt: fixedNow)
        let notes = SafetyNote.evaluate(profile)
        XCTAssertEqual(Set(notes), [.educationalModeMinor, .noEmergencyFund, .highInterestDebt, .shortHorizonVolatility, .unstableIncome, .lossAversionVsVolatility])
    }

    func testPriceSeriesAsOfExcludesFuture() {
        let key = ListingKey(mic: nil, ticker: Ticker(rawValue: "TEST")!)
        let series = PriceSeries(listing: key, currency: .usd, adjustment: .split, bars: [
            PriceBar(date: .d("2026-01-03"), close: 3), PriceBar(date: .d("2026-01-01"), close: 1), PriceBar(date: .d("2026-01-02"), close: 2),
        ])
        XCTAssertEqual(series.bars.map(\.close), [1, 2, 3])
        XCTAssertEqual(series.asOf(.d("2026-01-02")).bars.map(\.close), [1, 2])
        XCTAssertEqual(series.close(onOrBefore: .d("2026-01-10"))?.close, 3)
        XCTAssertNil(series.close(onOrBefore: .d("2026-02-10")))
        XCTAssertNil(series.close(onOrBefore: .d("2025-12-31")))
    }
}
