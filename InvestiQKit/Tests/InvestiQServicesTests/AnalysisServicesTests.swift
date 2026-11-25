import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence
import InvestiQTestSupport

final class AnalysisServicesTests: XCTestCase {
    struct Fixture {
        let clock: ManualTimeProvider
        let user: DatabaseStore
        let instruments: InstrumentService
        let market: MarketDataService
        let portfolios: PortfolioService
        let forecasts: ForecastService
        let risk: RiskService
    }

    /// `providerLagDays` makes the demo provider's data end that many days before "now" (stale input).
    func makeFixture(providerLagDays: Int = 0) async throws -> Fixture {
        let now = Date.utc("2026-11-20T15:00:00Z")
        let clock = ManualTimeProvider(now)
        let providerClock = ManualTimeProvider(now.addingTimeInterval(-Double(providerLagDays) * 86_400))
        let user = try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .inMemoryOnly, now: now)
        let cache = try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: now)
        let registry = ProviderRegistry.demo(clock: providerLagDays == 0 ? clock : providerClock)
        let market = MarketDataService(registry: registry, cache: cache, clock: clock)
        let rates = ExchangeRateService(providers: registry.exchangeRates, cache: cache, clock: clock)
        let instruments = InstrumentService(store: user, clock: clock)
        try await instruments.seedDemoUniverse()
        let portfolios = PortfolioService(store: user, marketData: market, exchangeRates: rates, clock: clock)
        return Fixture(clock: clock, user: user, instruments: instruments, market: market, portfolios: portfolios,
                       forecasts: ForecastService(store: user, marketData: market, clock: clock),
                       risk: RiskService(store: user, portfolios: portfolios, instruments: instruments, marketData: market, clock: clock))
    }

    func testTargetDateSkipsWeekends() {
        // Friday 2026-11-20 + 1 trading day = Monday 2026-11-23; + 5 = Friday 2026-11-27.
        XCTAssertEqual(ForecastService.targetDate(from: .d("2026-11-20"), tradingDays: 1), .d("2026-11-23"))
        XCTAssertEqual(ForecastService.targetDate(from: .d("2026-11-20"), tradingDays: 5), .d("2026-11-27"))
    }

    func testForecastIsStoredAppendOnlyAndEvaluatedAfterTargetDate() async throws {
        let f = try await makeFixture()
        let demo = DemoUniverse.all[0]
        let row = try await f.forecasts.createForecast(instrumentID: demo.instrument.id, listing: demo.listing, model: .naive, horizon: 21)
        XCTAssertEqual(row.originDate, .d("2026-11-20"))
        XCTAssertEqual(row.targetDate, .d("2026-12-21"))
        XCTAssertFalse(row.staleInput)
        XCTAssertLessThanOrEqual(row.lower95, row.lower80)
        XCTAssertLessThanOrEqual(row.upper80, row.upper95)
        XCTAssertEqual(row.point, row.originValue, accuracy: 1e-9, "naive point forecast = last value")
        XCTAssertNotNil(row.validationMASE, "validation against the naive baseline is stored with the forecast")

        // The ledger is append-only: updates and deletes are rejected by triggers.
        let id = row.id
        do {
            try await f.user.write { try $0.run("UPDATE forecasts SET point = 1 WHERE id = ?", [.of(id)]) }
            XCTFail("forecast rows must be immutable")
        } catch {}
        do {
            try await f.user.write { try $0.run("DELETE FROM forecasts WHERE id = ?", [.of(id)]) }
            XCTFail("forecast rows must not be deleted")
        } catch {}

        // Nothing to evaluate before the target date.
        var evaluated = try await f.forecasts.evaluateDueForecasts()
        XCTAssertEqual(evaluated, 0)
        f.clock.set(Date.utc("2026-12-28T15:00:00Z"))
        evaluated = try await f.forecasts.evaluateDueForecasts()
        XCTAssertEqual(evaluated, 1)
        let stored = try await f.forecasts.forecasts()
        let evaluation = try XCTUnwrap(stored.first?.evaluation)
        XCTAssertEqual(evaluation.absoluteError, evaluation.naiveAbsoluteError, accuracy: 1e-9, "naive forecast equals its baseline")
        // Evaluating again does nothing (one evaluation per forecast).
        evaluated = try await f.forecasts.evaluateDueForecasts()
        XCTAssertEqual(evaluated, 0)
        let accuracy = try await f.forecasts.accuracy()
        XCTAssertEqual(accuracy.first?.evaluated, 1)
        XCTAssertEqual(accuracy.first?.pending, 0)
    }

    func testStaleInputIsRefusedUnlessExplicitlyAllowed() async throws {
        let f = try await makeFixture(providerLagDays: 20)
        let demo = DemoUniverse.all[2]
        do {
            _ = try await f.forecasts.createForecast(instrumentID: demo.instrument.id, listing: demo.listing, model: .drift, horizon: 21)
            XCTFail("stale input must be refused")
        } catch ForecastServiceError.model(.staleInput) {}
        let row = try await f.forecasts.createForecast(instrumentID: demo.instrument.id, listing: demo.listing, model: .drift, horizon: 21,
                                                       allowStaleInput: true)
        XCTAssertTrue(row.staleInput, "the override is recorded with the forecast")
    }

    func testRiskAssessmentCoversAllCategoriesAndIsRecorded() async throws {
        let f = try await makeFixture()
        let portfolio = try await f.portfolios.createPortfolio(name: "Main", kind: .real, baseCurrency: .czk)
        let stock = DemoUniverse.all[0], bond = DemoUniverse.all[10], etf = DemoUniverse.all[7]
        func buy(_ demo: DemoInstrument, _ quantity: Decimal, _ price: Decimal) -> Transaction {
            Transaction(portfolioID: portfolio.id, type: .buy, instrumentID: demo.instrument.id, listingID: demo.listing.id,
                        tradeDate: .d("2025-06-02"), quantity: quantity, price: price, currency: demo.listing.tradingCurrency,
                        createdAt: f.clock.now())
        }
        try await f.portfolios.add([buy(stock, 100, 500), buy(bond, 20, 1_000), buy(etf, 50, 100)])
        let assessment = try await f.risk.assess(portfolio.id)
        XCTAssertEqual(assessment.holdings.count, 3)
        XCTAssertEqual(Set(assessment.report.categories.map(\.category)), Set(RiskCategory.allCases))
        XCTAssertNotNil(assessment.report.weightedModifiedDuration, "the government bond contributes duration")
        XCTAssertFalse(assessment.holdings.contains { $0.dailyReturns.isEmpty }, "returns come from the demo history")
        XCTAssertEqual(assessment.report.byAssetType.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
        let count = try await f.user.read { try RiskRecords.count(portfolioID: portfolio.id, in: $0) }
        XCTAssertEqual(count, 1)
    }

    func testBondPositionsAreValuedFromPercentOfFaceQuotes() async throws {
        let f = try await makeFixture()
        let bond = DemoUniverse.all[10]
        let terms = try XCTUnwrap(bond.bond)
        XCTAssertEqual(terms.faceValue, 10_000)
        let portfolio = try await f.portfolios.createPortfolio(name: "Bonds", kind: .real, baseCurrency: .czk)
        // Two bonds bought at 101.20 % of 10 000 CZK face = 10 120 CZK each (the ledger records the price of one bond).
        try await f.portfolios.add([Transaction(portfolioID: portfolio.id, type: .buy, instrumentID: bond.instrument.id,
                                                listingID: bond.listing.id, tradeDate: .d("2026-03-02"), quantity: 2,
                                                price: terms.unitPrice(fromPercentOfFace: Decimal(string: "101.20")!),
                                                currency: .czk, createdAt: f.clock.now())])
        let quoteOutcome = await f.market.quote(for: bond.listing)
        let quote = try XCTUnwrap(quoteOutcome.value?.value.price)
        XCTAssertLessThan(quote, 150, "bond quotes are percent of face value")
        let snapshot = try await f.portfolios.snapshot(portfolio.id)
        let holding = try XCTUnwrap(snapshot.valuation.holdings.first)
        XCTAssertEqual(holding.marketValue, 2 * quote * 100)
        XCTAssertEqual(holding.position.costBasis, 20_240)
        let assessment = try await f.risk.assess(portfolio.id)
        XCTAssertEqual(try XCTUnwrap(assessment.holdings.first?.bondCleanPrice), quote.doubleValue, accuracy: 1e-9)
    }
}
