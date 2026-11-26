import Foundation
import InvestiQCore

/// One holding as seen by the risk engine (values in the portfolio base currency).
public struct RiskHolding: Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: InstrumentKind
    public var valueBase: Double
    public var currency: CurrencyCode
    public var country: String?
    public var sector: String?
    public var issuer: String?
    public var beta: Double?
    public var bond: BondDetails?
    public var bondCleanPrice: Double?
    public var etf: ETFDetails?
    /// Average daily traded value in base currency (liquidity), if known.
    public var averageDailyValueBase: Double?
    public var dailyReturns: [Double]

    public init(id: String, name: String, kind: InstrumentKind, valueBase: Double, currency: CurrencyCode, country: String? = nil,
                sector: String? = nil, issuer: String? = nil, beta: Double? = nil, bond: BondDetails? = nil, bondCleanPrice: Double? = nil,
                etf: ETFDetails? = nil, averageDailyValueBase: Double? = nil, dailyReturns: [Double] = []) {
        self.id = id; self.name = name; self.kind = kind; self.valueBase = valueBase; self.currency = currency; self.country = country
        self.sector = sector; self.issuer = issuer; self.beta = beta; self.bond = bond; self.bondCleanPrice = bondCleanPrice; self.etf = etf
        self.averageDailyValueBase = averageDailyValueBase; self.dailyReturns = dailyReturns
    }

    /// Bond ETFs are recognised from the tracked index name (heuristic, shown as an assumption).
    public var isBondETF: Bool {
        guard kind == .etf, let index = etf?.indexName?.lowercased() else { return false }
        return ["bond", "treasury", "government", "aggregate", "credit", "anleihe", "dluhopis"].contains { index.contains($0) }
    }
}

public enum RiskLevel: String, Sendable, CaseIterable, Comparable {
    case low, moderate, elevated, high, unknown
    var order: Int { [.low: 0, .moderate: 1, .elevated: 2, .high: 3, .unknown: -1][self] ?? -1 }
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

public enum RiskCategory: String, Sendable, CaseIterable {
    case market, credit, liquidity, currency, inflation, concentration, interestRate, political, regulatory, counterparty
}

public struct RiskCategoryAssessment: Sendable, Equatable {
    public var category: RiskCategory
    public var level: RiskLevel
    /// The figure the level is based on (fraction or years), if quantitative.
    public var metric: Double?
    public var isQualitative: Bool
    public var explanation: Message
}

public struct ExposureItem: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public var label: String
    public var valueBase: Double
    public var weight: Double
}

public struct PortfolioRiskReport: Sendable {
    public var totalValueBase: Double
    public var byIssuer: [ExposureItem]
    public var bySector: [ExposureItem]
    public var byCountry: [ExposureItem]
    public var byCurrency: [ExposureItem]
    public var byAssetType: [ExposureItem]
    public var herfindahl: Double?
    public var effectivePositions: Double?
    public var annualVolatility: Double?
    /// 1-day historical VaR at 95 % as a positive fraction of value — not the maximum possible loss.
    public var valueAtRisk95: Double?
    public var conditionalVaR95: Double?
    public var weightedModifiedDuration: Double?
    public var correlations: [CorrelationPair]
    public var categories: [RiskCategoryAssessment]
    public var methodVersion: String
}

public struct CorrelationPair: Sendable, Hashable {
    public var first: String
    public var second: String
    public var correlation: Double
}

public struct RiskEngine: Sendable {
    public static let methodVersion = "risk-1"
    /// Exposure labels for cash are `cash:<ISO code>`; the UI localises them.
    public static let cashLabelPrefix = "cash:"
    /// Developed markets for the political-risk heuristic (ISO 3166-1 alpha-2).
    static let developedMarkets: Set<String> = [
        "AT", "BE", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PL", "PT",
        "SE", "SI", "SK", "HU", "BG", "RO", "NO", "IS", "LI", "CH", "GB", "US", "CA", "JP", "AU", "NZ", "SG", "HK", "IL",
    ]
    static let investmentGrade = ["AAA", "AA+", "AA", "AA-", "A+", "A", "A-", "BBB+", "BBB", "BBB-"]

    public let baseCurrency: CurrencyCode
    public let settlement: LocalDate

    public init(baseCurrency: CurrencyCode, settlement: LocalDate) {
        self.baseCurrency = baseCurrency
        self.settlement = settlement
    }

    // MARK: Report

    public func report(holdings: [RiskHolding], cashBase: Double, portfolioDailyReturns: [Double]) -> PortfolioRiskReport {
        let invested = holdings.reduce(0) { $0 + max(0, $1.valueBase) }
        let total = invested + max(0, cashBase)
        func exposures(_ key: (RiskHolding) -> [(String, Double)]) -> [ExposureItem] {
            var sums: [String: Double] = [:]
            for holding in holdings { for (label, value) in key(holding) { sums[label, default: 0] += value } }
            guard total > 0 else { return [] }
            return sums.map { ExposureItem(label: $0.key, valueBase: $0.value, weight: $0.value / total) }.sorted { $0.valueBase > $1.valueBase }
        }
        let byIssuer = exposures { [($0.issuer ?? $0.name, $0.valueBase)] }
        let byCurrency = exposures(currencyLookThrough) + (cashBase > 0 ? [ExposureItem(label: Self.cashLabelPrefix + baseCurrency.rawValue, valueBase: cashBase, weight: total > 0 ? cashBase / total : 0)] : [])
        let weights = holdings.map { total > 0 ? $0.valueBase / total : 0 }
        let hhi = total > 0 && !holdings.isEmpty ? weights.reduce(0) { $0 + $1 * $1 } : nil
        let volatility = portfolioDailyReturns.count >= Performance.minimumReturns
            ? Statistics.standardDeviation(portfolioDailyReturns).map { $0 * Performance.tradingDaysPerYear.squareRoot() } : nil
        let (varValue, cvar) = historicalVaR(portfolioDailyReturns)
        let duration = weightedDuration(holdings, total: total)
        var report = PortfolioRiskReport(
            totalValueBase: total, byIssuer: byIssuer, bySector: exposures { [($0.sector ?? "—", $0.valueBase)] },
            byCountry: exposures { [($0.country ?? "—", $0.valueBase)] }, byCurrency: byCurrency,
            byAssetType: exposures { [($0.isBondETF ? "bondETF" : $0.kind.rawValue, $0.valueBase)] },
            herfindahl: hhi, effectivePositions: hhi.flatMap { $0 > 0 ? 1 / $0 : nil }, annualVolatility: volatility,
            valueAtRisk95: varValue, conditionalVaR95: cvar, weightedModifiedDuration: duration,
            correlations: correlations(holdings), categories: [], methodVersion: Self.methodVersion)
        report.categories = categories(report: report, holdings: holdings, cashBase: cashBase)
        return report
    }

    /// ETF currency look-through when the fund's currency exposure is known; otherwise trading currency.
    func currencyLookThrough(_ holding: RiskHolding) -> [(String, Double)] {
        if let exposure = holding.etf?.currencyExposure, !exposure.isEmpty {
            return exposure.map { ($0.label, holding.valueBase * $0.weight.doubleValue) }
        }
        return [(holding.currency.rawValue, holding.valueBase)]
    }

    /// M-VAR-1: empirical 5 % quantile of daily returns (needs ≥ 250 observations).
    func historicalVaR(_ returns: [Double]) -> (Double?, Double?) {
        guard returns.count >= 250, let q = Statistics.quantile(returns, 0.05) else { return (nil, nil) }
        let tail = returns.filter { $0 <= q }
        return (max(0, -q), tail.isEmpty ? nil : max(0, -(tail.reduce(0, +) / Double(tail.count))))
    }

    /// Value-weighted modified duration of bonds (bond ETFs use an assumed 7-year duration — labelled).
    static let assumedBondETFDuration = 7.0

    func weightedDuration(_ holdings: [RiskHolding], total: Double) -> Double? {
        guard total > 0 else { return nil }
        var sum = 0.0
        var hasFixedIncome = false
        for holding in holdings {
            if let bond = holding.bond, let price = holding.bondCleanPrice {
                let math = BondMath(terms: bond)
                if let ytm = math.yieldToMaturity(clean: price, settlement: settlement),
                   let risk = math.riskMeasures(yield: ytm, settlement: settlement) {
                    sum += holding.valueBase / total * risk.modified
                    hasFixedIncome = true
                }
            } else if holding.isBondETF {
                sum += holding.valueBase / total * Self.assumedBondETFDuration
                hasFixedIncome = true
            }
        }
        return hasFixedIncome ? sum : 0
    }

    func correlations(_ holdings: [RiskHolding]) -> [CorrelationPair] {
        var pairs: [CorrelationPair] = []
        for i in holdings.indices {
            for j in holdings.indices where j > i {
                let a = holdings[i].dailyReturns, b = holdings[j].dailyReturns
                let n = min(a.count, b.count)
                guard n >= Performance.minimumReturns,
                      let c = Statistics.correlation(Array(a.suffix(n)), Array(b.suffix(n))) else { continue }
                pairs.append(CorrelationPair(first: holdings[i].name, second: holdings[j].name, correlation: c))
            }
        }
        return pairs.sorted { abs($0.correlation) > abs($1.correlation) }
    }

    // MARK: Categories (thresholds documented in docs/FINANCIAL_METHODOLOGY.md §3)

    func level(_ value: Double?, _ thresholds: (Double, Double, Double)) -> RiskLevel {
        guard let value else { return .unknown }
        if value < thresholds.0 { return .low }
        if value < thresholds.1 { return .moderate }
        if value < thresholds.2 { return .elevated }
        return .high
    }

    func categories(report: PortfolioRiskReport, holdings: [RiskHolding], cashBase: Double) -> [RiskCategoryAssessment] {
        let total = report.totalValueBase
        func share(_ predicate: (RiskHolding) -> Bool) -> Double {
            total > 0 ? holdings.filter(predicate).reduce(0) { $0 + $1.valueBase } / total : 0
        }
        let bonds = holdings.filter { $0.bond != nil }
        let belowInvestmentGrade = share { h in h.bond != nil && !Self.investmentGrade.contains(h.bond?.creditRating ?? "") }
        let foreignCurrency = total > 0 ? report.byCurrency.filter { $0.label != baseCurrency.rawValue && $0.label != Self.cashLabelPrefix + baseCurrency.rawValue }.reduce(0) { $0 + $1.valueBase } / total : 0
        let fixedIncomeAndCash = share { $0.bond != nil || $0.isBondETF } + (total > 0 ? max(0, cashBase) / total : 0)
        let illiquid = share { h in
            if let adv = h.averageDailyValueBase, adv > 0 { return h.valueBase / (0.2 * adv) > 5 }
            return h.bond != nil
        }
        let topWeight = report.byIssuer.first?.weight
        let emerging = share { h in h.country.map { !Self.developedMarkets.contains($0) } ?? false }
        let nonUCITSFunds = share { h in h.kind == .etf && h.etf?.isUCITS == false }
        let synthetic = share { $0.etf?.replication == .synthetic }
        let cashShare = total > 0 ? max(0, cashBase) / total : 0

        var concentrationLevel = RiskLevel.low
        if let top = topWeight, let hhi = report.herfindahl {
            if top > 0.4 || hhi > 0.25 { concentrationLevel = .high }
            else if top > 0.2 || hhi > 0.15 { concentrationLevel = .elevated }
            else if top > 0.1 { concentrationLevel = .moderate }
        } else {
            concentrationLevel = .unknown
        }
        return [
            RiskCategoryAssessment(category: .market, level: level(report.annualVolatility, (0.08, 0.15, 0.25)), metric: report.annualVolatility,
                                   isQualitative: false, explanation: Message("risk.market.explanation")),
            RiskCategoryAssessment(category: .credit, level: bonds.isEmpty ? .low : level(belowInvestmentGrade, (0.0001, 0.10, 0.30)),
                                   metric: belowInvestmentGrade, isQualitative: false,
                                   explanation: Message(bonds.isEmpty ? "risk.credit.noBonds" : "risk.credit.explanation")),
            RiskCategoryAssessment(category: .liquidity, level: level(illiquid, (0.10, 0.30, 0.60)), metric: illiquid, isQualitative: false,
                                   explanation: Message("risk.liquidity.explanation")),
            RiskCategoryAssessment(category: .currency, level: level(foreignCurrency, (0.10, 0.40, 0.70)), metric: foreignCurrency,
                                   isQualitative: false, explanation: Message("risk.currency.explanation")),
            RiskCategoryAssessment(category: .inflation, level: level(fixedIncomeAndCash, (0.20, 0.50, 0.80)), metric: fixedIncomeAndCash,
                                   isQualitative: false, explanation: Message("risk.inflation.explanation")),
            RiskCategoryAssessment(category: .concentration, level: concentrationLevel, metric: topWeight, isQualitative: false,
                                   explanation: Message("risk.concentration.explanation")),
            RiskCategoryAssessment(category: .interestRate, level: level(report.weightedModifiedDuration, (1, 3, 6)),
                                   metric: report.weightedModifiedDuration, isQualitative: false,
                                   explanation: Message("risk.interestRate.explanation")),
            RiskCategoryAssessment(category: .political, level: level(emerging, (0.10, 0.30, 0.60)), metric: emerging, isQualitative: true,
                                   explanation: Message("risk.political.explanation")),
            RiskCategoryAssessment(category: .regulatory, level: nonUCITSFunds > 0 ? .moderate : .low, metric: nonUCITSFunds, isQualitative: true,
                                   explanation: Message("risk.regulatory.explanation")),
            RiskCategoryAssessment(category: .counterparty, level: (synthetic > 0 || cashShare > 0.5) ? .moderate : .low,
                                   metric: max(synthetic, cashShare), isQualitative: true, explanation: Message("risk.counterparty.explanation")),
        ]
    }

    // MARK: Stress tests (hypothetical — FINANCIAL_METHODOLOGY §7)

    public enum StressScenario: Sendable, Hashable {
        case equityDecline(Double)
        case interestRateShift(Double)
        case inflation(annualRate: Double, years: Int)
        /// Base currency appreciates by the fraction (foreign assets lose that much in base terms).
        case baseCurrencyAppreciation(Double)
        case creditSpreadWidening(issuer: String?, spread: Double)
        case issuerDefault(issuer: String, recoveryRate: Double)
        case singleCompanyDecline(issuer: String, decline: Double)
    }

    public struct StressLine: Sendable, Hashable {
        public var name: String
        public var changeBase: Double
        public var usedAssumption: Bool
    }

    public struct StressResult: Sendable {
        public var scenario: StressScenario
        public var changeBase: Double
        public var changeFraction: Double?
        public var lines: [StressLine]
        public var assumptions: [Message]
    }

    public func stress(_ scenario: StressScenario, holdings: [RiskHolding], cashBase: Double) -> StressResult {
        var lines: [StressLine] = []
        var assumptions: [Message] = [Message("stress.hypothetical")]
        let total = holdings.reduce(0) { $0 + $1.valueBase } + max(0, cashBase)
        func add(_ holding: RiskHolding, _ change: Double, assumed: Bool = false) {
            if change != 0 { lines.append(StressLine(name: holding.name, changeBase: change, usedAssumption: assumed)) }
        }
        switch scenario {
        case .equityDecline(let decline):
            for holding in holdings where (holding.kind == .stock || holding.kind == .etf) && !holding.isBondETF {
                let assumed = holding.beta == nil
                add(holding, -holding.valueBase * decline * (holding.beta ?? 1), assumed: assumed)
            }
            assumptions.append(Message("stress.assumption.beta"))
        case .interestRateShift(let shift):
            for holding in holdings {
                if let bond = holding.bond, let price = holding.bondCleanPrice,
                   let change = BondMath(terms: bond).cleanPriceChange(clean: price, settlement: settlement, yieldShift: shift) {
                    add(holding, holding.valueBase * change / price)
                } else if holding.isBondETF {
                    add(holding, -holding.valueBase * Self.assumedBondETFDuration * shift, assumed: true)
                }
            }
            assumptions.append(Message("stress.assumption.rates"))
        case .inflation(let rate, let years):
            // Real (purchasing-power) loss of nominal fixed-income and cash; equities are not modelled.
            let factor = 1 - 1 / pow(1 + rate, Double(years))
            for holding in holdings where holding.bond != nil || holding.isBondETF { add(holding, -holding.valueBase * factor) }
            if cashBase > 0 { lines.append(StressLine(name: Self.cashLabelPrefix + baseCurrency.rawValue, changeBase: -cashBase * factor, usedAssumption: false)) }
            assumptions.append(Message("stress.assumption.inflation"))
        case .baseCurrencyAppreciation(let move):
            for holding in holdings {
                let foreign = currencyLookThrough(holding).filter { $0.0 != baseCurrency.rawValue && $0.0 != "Other" }.reduce(0) { $0 + $1.1 }
                add(holding, -foreign * move)
            }
            assumptions.append(Message("stress.assumption.currency"))
        case .creditSpreadWidening(let issuer, let spread):
            for holding in holdings where holding.kind == .corporateBond && (issuer == nil || holding.issuer == issuer) {
                if let bond = holding.bond, let price = holding.bondCleanPrice,
                   let change = BondMath(terms: bond).cleanPriceChange(clean: price, settlement: settlement, yieldShift: spread) {
                    add(holding, holding.valueBase * change / price)
                }
            }
            assumptions.append(Message("stress.assumption.credit"))
        case .issuerDefault(let issuer, let recovery):
            for holding in holdings where holding.issuer == issuer {
                add(holding, holding.bond != nil ? -holding.valueBase * (1 - recovery) : -holding.valueBase)
            }
            assumptions.append(Message("stress.assumption.default"))
        case .singleCompanyDecline(let issuer, let decline):
            for holding in holdings where holding.issuer == issuer { add(holding, -holding.valueBase * decline) }
        }
        let change = lines.reduce(0) { $0 + $1.changeBase }
        return StressResult(scenario: scenario, changeBase: change, changeFraction: total > 0 ? change / total : nil,
                            lines: lines.sorted { $0.changeBase < $1.changeBase }, assumptions: assumptions)
    }
}
