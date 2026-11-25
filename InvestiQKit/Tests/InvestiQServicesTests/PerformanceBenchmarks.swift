import XCTest
@testable import InvestiQServices
@testable import InvestiQAnalytics
@testable import InvestiQPersistence
import InvestiQCore
import InvestiQData
import InvestiQSecurity
import InvestiQTestSupport

/// Timings for docs/reports/PERFORMANCE_REPORT.md. Each benchmark prints `BENCH <name> <ms>` and asserts a
/// generous ceiling so regressions fail the build without making CI flaky.
final class PerformanceBenchmarks: XCTestCase {
    func time(_ name: String, ceilingSeconds: Double, _ body: () throws -> Void) rethrows {
        let clock = ContinuousClock()
        let elapsed = try clock.measure(body)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "BENCH %@ %.1f ms", name, ms))
        XCTAssertLessThan(ms / 1000, ceilingSeconds, name)
    }

    func largeLedger(count: Int) -> [Transaction] {
        let portfolio = PortfolioID()
        let instruments = (0..<20).map { _ in InstrumentID() }
        var result = [Transaction(portfolioID: portfolio, type: .deposit, tradeDate: .d("2015-01-02"), amount: 100_000_000, currency: .czk,
                                  createdAt: fixedNow)]
        var date = LocalDate.d("2015-01-05")
        for index in 0..<count {
            let instrument = instruments[index % instruments.count]
            // Per instrument: two buying rounds, then each round of five is buy, buy, buy, dividend, sell.
            let round = index / instruments.count
            let type: TransactionType = round < 2 ? .buy : (round % 5 == 4 ? .sell : (round % 5 == 3 ? .dividend : .buy))
            switch type {
            case .dividend:
                result.append(Transaction(portfolioID: portfolio, type: .dividend, instrumentID: instrument, tradeDate: date, amount: 12,
                                          currency: .czk, taxWithheld: 2, createdAt: fixedNow))
            default:
                result.append(Transaction(portfolioID: portfolio, type: type, instrumentID: instrument, tradeDate: date, quantity: type == .sell ? 1 : 3,
                                          price: Decimal(100 + index % 50), currency: .czk, fees: 1, createdAt: fixedNow))
            }
            if index % 4 == 3 { date = date.adding(days: 1) }
        }
        return result
    }

    func testBenchmarks() throws {
        let transactions = largeLedger(count: 10_000)
        try time("ledger-replay-10k", ceilingSeconds: 5) { _ = try PortfolioLedger(baseCurrency: .czk).replay(transactions) }
        try time("ledger-hash-10k", ceilingSeconds: 5) { _ = try PortfolioService.ledgerHash(transactions) }

        // Encrypted persistence of a database holding the 10k ledger.
        let directory = try TemporaryDirectory()
        let file = EncryptedDatabaseFile(url: directory.url.appendingPathComponent("bench.iqdb"), kind: .user, profileID: ProfileID(),
                                         key: CryptoBox.randomKey())
        let db = try SQLiteDatabase()
        try Migrator.migrate(db, migrations: UserSchema.migrations, now: fixedNow)
        let portfolio = Portfolio(id: transactions[0].portfolioID, name: "Bench", kind: .real, baseCurrency: .czk, createdAt: fixedNow)
        try db.transaction {
            try PortfolioRecords.insert(portfolio, in: db)
            for id in Set(transactions.compactMap(\.instrumentID)) {
                try InstrumentRecords.upsert(Instrument(id: id, kind: .stock, name: "I\(id.string.prefix(4))", currency: .czk, source: "bench", createdAt: fixedNow), in: db)
            }
            for transaction in transactions { try TransactionRecords.insert(transaction, in: db) }
        }
        try time("encrypted-save-10k", ceilingSeconds: 3) { try file.write(image: try db.serialize(), schemaVersion: db.userVersion) }
        try time("encrypted-open-10k", ceilingSeconds: 3) { _ = try SQLiteDatabase(image: try XCTUnwrap(file.read()).image) }

        // Ten years of daily prices for analytics.
        let demo = DemoUniverse.all[7]
        let bars = DemoUniverse.history(for: demo, through: .d("2026-11-20"))
        let series = PriceSeries(listing: demo.listing.key, currency: .eur, adjustment: .split, bars: bars)
        time("walk-forward-bootstrap-10y", ceilingSeconds: 60) {
            _ = WalkForwardValidator(horizon: 21, step: 21).validate(.bootstrap, series: series)
        }
        let returns = Performance.logReturns(Performance.closes(series))
        let holdings = (0..<20).map { index in
            RiskHolding(id: "\(index)", name: "H\(index)", kind: .stock, valueBase: Double(1_000 + index * 100), currency: .eur, country: "DE",
                        sector: "S\(index % 5)", issuer: "I\(index)", dailyReturns: Array(returns.suffix(252)))
        }
        time("risk-report-20-holdings", ceilingSeconds: 5) {
            _ = RiskEngine(baseCurrency: .czk, settlement: .d("2026-11-20")).report(holdings: holdings, cashBase: 0,
                                                                                    portfolioDailyReturns: Array(returns.suffix(252)))
        }
        let assets = [0, 7, 9].map { index in
            StrategyBacktest.Asset(key: "\(index)", name: "\(index)", targetWeight: 1.0 / 3,
                                   series: PriceSeries(listing: DemoUniverse.all[index].listing.key, currency: .czk, adjustment: .split,
                                                       bars: DemoUniverse.history(for: DemoUniverse.all[index], through: .d("2026-11-20"))))
        }
        try time("backtest-3-assets-10y", ceilingSeconds: 10) {
            _ = try StrategyBacktest(assets: assets, baseCurrency: .czk, fees: .standard, rebalancing: .quarterly, rate: { _, _ in 1 })
                .run(initial: 100_000, monthly: 1_000, from: .d("2016-01-04"), to: .d("2026-11-20"))
        }
        let items = (0..<500).map { index in
            NewsArticle(id: "\(index)", canonicalURL: "https://n.example/\(index % 400)", url: URL(string: "https://n.example/\(index)")!,
                        headline: "Central bank keeps interest rates unchanged as inflation slows \(index % 300)", summary: nil,
                        sourceName: "S\(index % 7)", alsoReportedBy: [], providerID: "x", publishedAt: fixedNow.addingTimeInterval(Double(index) * 60),
                        eventDate: nil, categories: [], statementType: .reported, statementCue: nil, uncertainty: .medium,
                        relatedInstrumentIDs: [], relatedSectors: [], isDemo: false)
        }
        time("news-classify-and-dedup-500", ceilingSeconds: 20) {
            for item in items { _ = NewsClassifier.classify(headline: item.headline, summary: nil, isOfficial: false) }
            _ = NewsDeduplicator.merge(items)
        }
        try time("argon2id-production-unlock", ceilingSeconds: 10) {
            let kdf = Argon2idKeyDerivation()
            _ = try kdf.deriveKey(password: "benchmark password", parameters: kdf.makeParameters())
        }
    }
}
