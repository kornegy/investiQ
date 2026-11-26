import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence
import InvestiQTestSupport

final class SimulatorServiceTests: XCTestCase {
    func makeService() async throws -> (SimulatorService, PortfolioService, ManualTimeProvider, MarketDataService) {
        let clock = ManualTimeProvider(Date.utc("2026-11-20T15:00:00Z"))
        let user = try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let cache = try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let registry = ProviderRegistry.demo(clock: clock)
        let market = MarketDataService(registry: registry, cache: cache, clock: clock)
        let rates = ExchangeRateService(providers: registry.exchangeRates, cache: cache, clock: clock)
        let instruments = InstrumentService(store: user, clock: clock)
        try await instruments.seedDemoUniverse()
        let portfolios = PortfolioService(store: user, marketData: market, exchangeRates: rates, clock: clock)
        return (SimulatorService(store: user, portfolios: portfolios, instruments: instruments, marketData: market, exchangeRates: rates,
                                 clock: clock), portfolios, clock, market)
    }

    func testHistoricalSessionTradesWithCostsAndNeverSeesLaterData() async throws {
        let (simulator, portfolios, _, market) = try await makeService()
        let usdStock = DemoUniverse.all[4], world = DemoUniverse.all[7]
        let overview = try await simulator.createSession(name: "History", mode: .historical, startingCapital: 100_000, currency: .czk,
                                                         startDate: .d("2025-01-06"), benchmark: world.instrument.id)
        let id = overview.portfolio.id
        XCTAssertEqual(overview.portfolio.kind, .virtual)

        // The reference price is the close on the simulated date, not today's quote.
        let (_, price) = try await simulator.referencePrice(usdStock.instrument.id, session: overview.session)
        let historyOutcome = await market.history(for: usdStock.listing, range: DateRange(start: .d("2024-12-20"), end: .d("2025-01-06")))
        let history = try XCTUnwrap(historyOutcome.value)
        XCTAssertEqual(price.value, history.value.close(onOrBefore: .d("2025-01-06"))?.close)

        let preview = try await simulator.place(id, instrumentID: usdStock.instrument.id, side: .buy, quantity: 20)
        XCTAssertGreaterThan(preview.fxFeeBase, 0)
        let transactions = try await portfolios.transactions(id)
        XCTAssertEqual(transactions.map(\.type), [.deposit, .fxConversion, .buy])
        XCTAssertTrue(transactions.allSatisfy { $0.source == .simulator && $0.tradeDate == .d("2025-01-06") })
        let snapshot = try await portfolios.snapshot(id, asOf: .d("2025-01-06"))
        // Cash falls by the order value, commission and FX fee (the conversion uses the unrounded trade value,
        // so the match is within a few hundredths).
        XCTAssertEqual((snapshot.ledger.cash[.czk] ?? 0).doubleValue, (100_000 - preview.netCashBase).doubleValue, accuracy: 0.5)
        XCTAssertEqual(snapshot.ledger.cash[.usd] ?? 1, 0, "converted cash is fully used by the purchase")

        do {
            try await simulator.place(id, instrumentID: usdStock.instrument.id, side: .buy, quantity: 100_000)
            XCTFail("orders beyond the available cash are rejected")
        } catch SimulatorError.insufficientCash {}
        do {
            try await simulator.place(id, instrumentID: usdStock.instrument.id, side: .sell, quantity: 21)
            XCTFail("selling more than held is rejected")
        } catch SimulatorError.insufficientQuantity(let available) { XCTAssertEqual(available, 20) }

        let advanced = try await simulator.advance(id, to: .d("2025-06-02"))
        XCTAssertEqual(advanced.simDate, .d("2025-06-02"))
        do {
            _ = try await simulator.advance(id, to: .d("2025-03-01"))
            XCTFail("a historical session cannot move backwards")
        } catch SimulatorError.cannotMoveBackwards {}
        try await simulator.place(id, instrumentID: usdStock.instrument.id, side: .sell, quantity: 5)
        let report = try await simulator.report(id)
        XCTAssertEqual(report.tradeCount, 2)
        XCTAssertGreaterThan(report.costsBase, 0)
        XCTAssertNotNil(report.valueBase)
        XCTAssertNotNil(report.benchmarkValueBase, "the benchmark receives the same deposit")
        XCTAssertEqual(report.benchmarkName, world.instrument.name)
        XCTAssertTrue(report.snapshot.valuation.holdings.allSatisfy {
            ($0.price?.metadata.marketTimestamp ?? .distantFuture) <= Date.utc("2025-06-03T00:00:00Z")
        }, "valuation uses prices up to the simulated date only")
    }

    func testLiveSessionAndValidation() async throws {
        let (simulator, portfolios, _, _) = try await makeService()
        do {
            _ = try await simulator.createSession(name: "x", mode: .historical, startingCapital: 1_000, currency: .czk,
                                                  startDate: .d("2026-11-10"), benchmark: nil)
            XCTFail("historical sessions must start at least 30 days back")
        } catch SimulatorError.invalidStartDate {}
        do {
            _ = try await simulator.createSession(name: "x", mode: .live, startingCapital: 0, currency: .czk, startDate: nil, benchmark: nil)
            XCTFail("capital must be positive")
        } catch SimulatorError.invalidCapital {}
        let live = try await simulator.createSession(name: "Live", mode: .live, startingCapital: 50_000, currency: .czk, startDate: nil,
                                                     benchmark: nil)
        XCTAssertEqual(live.session.startDate, .d("2026-11-20"))
        let czStock = DemoUniverse.all[0]
        try await simulator.place(live.portfolio.id, instrumentID: czStock.instrument.id, side: .buy, quantity: 10)
        let transactions = try await portfolios.transactions(live.portfolio.id)
        XCTAssertEqual(transactions.last?.tradeDate, .d("2026-11-20"))
        let sessions = try await simulator.sessions()
        XCTAssertEqual(sessions.count, 1)
        do {
            _ = try await simulator.advance(live.portfolio.id, to: .d("2026-11-21"))
            XCTFail("live sessions do not advance")
        } catch SimulatorError.notHistorical {}
    }

    func testStrategyBacktestOnDemoData() async throws {
        let (simulator, _, _, _) = try await makeService()
        let world = DemoUniverse.all[7], bonds = DemoUniverse.all[9]
        let request = SimulatorService.StrategyRequest(weights: [(world.instrument.id, 0.7), (bonds.instrument.id, 0.3)], initial: 100_000,
                                                       monthly: 2_000, start: .d("2020-01-02"), end: .d("2025-12-31"), rebalancing: .annually,
                                                       fees: .standard, baseCurrency: .czk, benchmark: world.instrument.id)
        let (strategy, benchmark) = try await simulator.backtest(request)
        XCTAssertGreaterThan(strategy.points.count, 1_000)
        XCTAssertEqual(strategy.contributed, 100_000 + 71 * 2_000, accuracy: 1e-6)
        XCTAssertGreaterThan(strategy.costs, 0)
        XCTAssertEqual(strategy.rebalances, 5)
        XCTAssertNotNil(benchmark?.maxDrawdown)
    }
}
