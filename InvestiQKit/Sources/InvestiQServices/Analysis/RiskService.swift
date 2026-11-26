import Foundation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence

public struct PortfolioRiskAssessment: Sendable {
    public var report: PortfolioRiskReport
    public var holdings: [RiskHolding]
    public var cashBase: Double
    public var baseCurrency: CurrencyCode
    public var computedAt: Date
}

/// Builds risk inputs from a portfolio and records an assessment history (risk_assessments).
public actor RiskService {
    private let store: DatabaseStore
    private let portfolios: PortfolioService
    private let instruments: InstrumentService
    private let marketData: MarketDataService
    private let clock: any TimeProvider

    public init(store: DatabaseStore, portfolios: PortfolioService, instruments: InstrumentService, marketData: MarketDataService,
                clock: any TimeProvider) {
        self.store = store
        self.portfolios = portfolios
        self.instruments = instruments
        self.marketData = marketData
        self.clock = clock
    }

    public func assess(_ portfolioID: PortfolioID) async throws -> PortfolioRiskAssessment {
        let snapshot = try await portfolios.snapshot(portfolioID)
        let today = clock.today()
        var holdings: [RiskHolding] = []
        for holding in snapshot.valuation.holdings {
            guard let valueBase = holding.marketValueBase?.doubleValue,
                  let instrument = snapshot.instruments[holding.position.key.instrumentID] else { continue }
            let entry = try? await instruments.entry(instrument.id)
            let bond = try? await instruments.bondDetails(instrument.id)
            let etf = try? await instruments.etfDetails(instrument.id)
            var returns: [Double] = []
            var beta: Double?
            var averageDailyValue: Double?
            if let listing = entry?.listing {
                if let series = await marketData.history(for: listing, range: DateRange(start: today.adding(years: -1), end: today)).value?.value {
                    returns = Performance.logReturns(Performance.closes(series))
                    let recent = series.bars.suffix(20)
                    let values = recent.compactMap { bar in bar.volume.map { ($0 * bar.close).doubleValue } }
                    if !values.isEmpty, let fx = holding.marketValueBase.flatMap({ base in holding.marketValue.map { base / $0 } }) {
                        averageDailyValue = values.reduce(0, +) / Double(values.count) * fx.doubleValue
                    }
                }
                if instrument.kind == .stock {
                    beta = await marketData.fundamentals(for: listing).value?.value.beta?.doubleValue
                }
            }
            // Holding prices are per bond (converted from the percent-of-face quote); analytics use per 100 of face.
            let cleanPer100 = bond.flatMap { terms in holding.price.flatMap { terms.percentOfFace(fromUnitPrice: $0.value)?.doubleValue } }
            holdings.append(RiskHolding(id: instrument.id.string, name: instrument.name, kind: instrument.kind, valueBase: valueBase,
                                        currency: holding.position.key.currency, country: instrument.country, sector: instrument.sector,
                                        issuer: instrument.issuer ?? instrument.name, beta: beta, bond: bond, bondCleanPrice: cleanPer100,
                                        etf: etf, averageDailyValueBase: averageDailyValue, dailyReturns: returns))
        }
        let cash = snapshot.ledger.tracksCash ? (snapshot.valuation.cashBase?.doubleValue ?? 0) : 0
        // Historical simulation with current weights: Σ w_i · r_i,t (local-currency returns; FX moves not included).
        let total = holdings.reduce(0) { $0 + $1.valueBase } + max(0, cash)
        let length = holdings.map(\.dailyReturns.count).filter { $0 > 0 }.min() ?? 0
        var portfolioReturns: [Double] = []
        if total > 0, length > 0 {
            for t in 0..<length {
                portfolioReturns.append(holdings.reduce(0) { sum, h in
                    guard h.dailyReturns.count >= length else { return sum }
                    return sum + h.valueBase / total * h.dailyReturns[h.dailyReturns.count - length + t]
                })
            }
        }
        let engine = RiskEngine(baseCurrency: snapshot.portfolio.baseCurrency, settlement: today)
        let report = engine.report(holdings: holdings, cashBase: cash, portfolioDailyReturns: portfolioReturns)
        let summary = report.categories.map { ["category": $0.category.rawValue, "level": $0.level.rawValue] }
        let now = clock.now()
        try await store.write { db in
            try RiskRecords.insert(portfolioID: portfolioID, computedAt: now, methodVersion: report.methodVersion,
                                   payloadJSON: try .json(summary), in: db)
        }
        return PortfolioRiskAssessment(report: report, holdings: holdings, cashBase: cash, baseCurrency: snapshot.portfolio.baseCurrency,
                                       computedAt: now)
    }
}
