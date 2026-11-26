import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQData
import InvestiQPersistence
import InvestiQTestSupport

final class PortfolioServiceTests: XCTestCase {
    let clock = ManualTimeProvider(Date.utc("2026-11-20T15:00:00Z"))

    func makeService() async throws -> (PortfolioService, InstrumentService, DatabaseStore) {
        let user = try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let cache = try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let registry = ProviderRegistry.demo(clock: clock)
        let market = MarketDataService(registry: registry, cache: cache, clock: clock)
        let rates = ExchangeRateService(providers: registry.exchangeRates, cache: cache, clock: clock)
        let instruments = InstrumentService(store: user, clock: clock)
        try await instruments.seedDemoUniverse()
        return (PortfolioService(store: user, marketData: market, exchangeRates: rates, clock: clock), instruments, user)
    }

    func buy(_ portfolio: PortfolioID, _ demo: DemoInstrument, _ quantity: Decimal, _ date: String) -> Transaction {
        Transaction(portfolioID: portfolio, type: .buy, instrumentID: demo.instrument.id, listingID: demo.listing.id, tradeDate: .d(date),
                    quantity: quantity, price: 100, currency: demo.listing.tradingCurrency, createdAt: clock.now())
    }

    func testAddRejectsOversellAndDeleteKeepsLedgerValid() async throws {
        let (service, _, _) = try await makeService()
        let portfolio = try await service.createPortfolio(name: " Main ", kind: .real, baseCurrency: .czk)
        XCTAssertEqual(portfolio.name, "Main")
        let demo = DemoUniverse.all[0]
        let first = buy(portfolio.id, demo, 10, "2026-01-05")
        try await service.add([first])
        let sell = Transaction(portfolioID: portfolio.id, type: .sell, instrumentID: demo.instrument.id, tradeDate: .d("2026-02-05"),
                               quantity: 11, price: 120, currency: .czk, createdAt: clock.now())
        do {
            try await service.add([sell])
            XCTFail("oversell must be rejected")
        } catch let PortfolioServiceError.ledger(.insufficientQuantity(_, available, _)) {
            XCTAssertEqual(available, 10)
        }
        var valid = sell
        valid.quantity = 10
        try await service.add([valid])
        do {
            try await service.delete(first)
            XCTFail("deleting the purchase would invalidate the later sale")
        } catch PortfolioServiceError.ledger {}
        let count = try await service.transactions(portfolio.id).count
        XCTAssertEqual(count, 2)
        do {
            _ = try await service.createPortfolio(name: "  ", kind: .real, baseCurrency: .czk)
            XCTFail("empty names are rejected")
        } catch {}
    }

    func testSimulatorTransactionsRequireVirtualPortfolio() async throws {
        let (service, _, _) = try await makeService()
        let real = try await service.createPortfolio(name: "Real", kind: .real, baseCurrency: .czk)
        var t = buy(real.id, DemoUniverse.all[0], 1, "2026-01-05")
        t.source = .simulator
        do {
            try await service.add([t])
            XCTFail("simulator trades never enter real portfolios")
        } catch {
            XCTAssertEqual(error as? PortfolioServiceError, .virtualOnly)
        }
    }

    func testCSVRoundTripIsIdempotentAndNeutralisesFormulas() async throws {
        let (service, _, _) = try await makeService()
        let source = try await service.createPortfolio(name: "Source", kind: .real, baseCurrency: .czk)
        let demo = DemoUniverse.all[0]
        var withFormula = buy(source.id, demo, 5, "2026-01-05")
        withFormula.notes = "=HYPERLINK(\"http://evil.example\")"
        try await service.add([
            Transaction(portfolioID: source.id, type: .deposit, tradeDate: .d("2026-01-02"), amount: 10_000, currency: .czk, createdAt: clock.now()),
            withFormula,
        ])
        let csv = try await service.exportCSV(source.id)
        XCTAssertTrue(csv.contains("'=HYPERLINK"), "formula cells are neutralised")
        XCTAssertTrue(csv.hasPrefix("date,type,isin"))

        let target = try await service.createPortfolio(name: "Target", kind: .real, baseCurrency: .czk)
        let parsed = TransactionCSV.parse(Data(csv.utf8))
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.rows.count, 2)
        let first = try await service.importRows(parsed.rows, into: target.id, now: clock.now())
        XCTAssertEqual(first, ImportOutcome(imported: 2, skippedDuplicates: 0, createdInstruments: 0))
        let second = try await service.importRows(parsed.rows, into: target.id, now: clock.now())
        XCTAssertEqual(second.imported, 0, "re-importing the same file never duplicates")
        XCTAssertEqual(second.skippedDuplicates, 2)
        let imported = try await service.transactions(target.id)
        XCTAssertEqual(imported.first { $0.type == .buy }?.instrumentID, demo.instrument.id, "instrument resolved by ISIN")
        XCTAssertTrue(imported.first { $0.type == .buy }?.notes?.hasPrefix("'=") == true, "the neutralising quote is kept as text")
    }

    func testCSVParsingErrorsAndEuropeanFormat() throws {
        let semicolon = """
        date;type;isin;ticker;name;quantity;price;currency;fees
        05.01.2026;buy;CZ0005112300;CEZ;ČEZ;10;1 024,50;CZK;49
        2026-13-01;buy;;;;1;1;CZK;0
        2026-01-06;teleport;;;;1;1;CZK;0
        2026-01-07;buy;US0378331006;;;1;1;USD;0
        2026-01-08;buy;;;;1;1;USD;0
        2026-01-09;deposit;;;;;;CZK;0
        """
        let result = TransactionCSV.parse(Data(semicolon.utf8))
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].price, Decimal(string: "1024.5"))
        XCTAssertEqual(result.rows[0].date, .d("2026-01-05"))
        XCTAssertEqual(result.errors.map(\.line), [3, 4, 5, 6])
        XCTAssertEqual(result.errors[0].message.key, "import.error.invalidDate")
        XCTAssertEqual(result.errors[2].message.key, "import.error.invalidISIN")
        XCTAssertEqual(result.errors[3].message.key, "import.error.missingInstrument")
        XCTAssertEqual(TransactionCSV.parse(Data("a,b\n1,2".utf8)).errors.first?.message.key, "import.error.missingColumns")
    }

    func testImportCreatesUnknownInstrumentsAndRejectsInvalidBatchAtomically() async throws {
        let (service, instruments, _) = try await makeService()
        let portfolio = try await service.createPortfolio(name: "Imp", kind: .real, baseCurrency: .czk)
        let csv = """
        date,type,isin,ticker,mic,name,quantity,price,currency
        2026-01-05,buy,,NEWCO,XPRA,New Company,10,100,CZK
        2026-01-06,sell,,NEWCO,XPRA,New Company,20,100,CZK
        """
        let parsed = TransactionCSV.parse(Data(csv.utf8))
        do {
            _ = try await service.importRows(parsed.rows, into: portfolio.id, now: clock.now())
            XCTFail("oversell inside the batch must abort the whole import")
        } catch PortfolioServiceError.ledger {}
        let afterFailure = try await service.transactions(portfolio.id)
        XCTAssertTrue(afterFailure.isEmpty)
        let libraryCount = try await instruments.library().count
        XCTAssertEqual(libraryCount, DemoUniverse.all.count, "the rolled-back import created no instruments")

        let ok = TransactionCSV.parse(Data(csv.replacingOccurrences(of: "sell,,NEWCO,XPRA,New Company,20", with: "sell,,NEWCO,XPRA,New Company,5").utf8))
        let outcome = try await service.importRows(ok.rows, into: portfolio.id, now: clock.now())
        XCTAssertEqual(outcome.createdInstruments, 1)
    }

    func testDemoPortfolioValuesWithSyntheticPricesAndSplits() async throws {
        let (service, _, _) = try await makeService()
        let portfolio = try await service.createPortfolio(name: DemoPortfolioSeeder.portfolioName, kind: .real, baseCurrency: .czk)
        try await service.add(DemoPortfolioSeeder.transactions(portfolioID: portfolio.id, baseCurrency: .czk, today: clock.today(),
                                                               createdAt: clock.now()))
        let snapshot = try await service.snapshot(portfolio.id)
        XCTAssertTrue(snapshot.valuation.missingPrices.isEmpty)
        XCTAssertTrue(snapshot.valuation.missingRates.isEmpty)
        XCTAssertNotNil(snapshot.valuation.totalValueBase)
        XCTAssertEqual(snapshot.valuation.returnBasis, .netContributions)
        XCTAssertEqual(snapshot.ledger.netContributionsBase, 500_000)
        let chips = DemoUniverse.all[5]
        let chipsPosition = try XCTUnwrap(snapshot.ledger.positions[PositionKey(instrumentID: chips.instrument.id, currency: .usd)])
        XCTAssertEqual(chipsPosition.quantity, 60 * 4 * 10, "both demo splits applied")
        XCTAssertEqual(snapshot.valuation.worstDelay, .synthetic)
        XCTAssertFalse(snapshot.ledgerHash.isEmpty)

        let performance = try await service.performance(portfolio.id, from: clock.today().adding(years: -1), to: clock.today())
        XCTAssertFalse(performance.hasGaps)
        XCTAssertNotNil(performance.timeWeightedReturn)
        XCTAssertNotNil(performance.moneyWeightedReturn)
        XCTAssertLessThan(performance.points.count, 120, "one year is sampled weekly")
        // The value series must agree with the snapshot on the last day.
        let last = try XCTUnwrap(performance.points.last?.value)
        let snapshotValue = try XCTUnwrap(snapshot.valuation.totalValueBase)
        XCTAssertLessThan(((last - snapshotValue) / snapshotValue).magnitudeValue, Decimal(string: "0.000001")!)
    }

    func testLedgerHashChangesWithContent() {
        let p = PortfolioID()
        let a = Transaction(portfolioID: p, type: .deposit, tradeDate: .d("2026-01-01"), amount: 1, currency: .czk, createdAt: fixedNow)
        var b = a
        b.amount = 2
        XCTAssertNotEqual(try PortfolioService.ledgerHash([a]), try PortfolioService.ledgerHash([b]))
        XCTAssertEqual(try PortfolioService.ledgerHash([a]), try PortfolioService.ledgerHash([a]))
    }
}
