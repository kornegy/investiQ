import Foundation
import InvestiQCore

/// A status together with the published rule that triggered it (docs/FINANCIAL_METHODOLOGY.md §9).
public struct TriggeredStatus: Sendable, Hashable {
    public var status: AnalyticalStatus
    public var rule: Message
}

/// Neutral, rule-based assessment plus an investment-thesis worksheet with arguments on both sides.
/// It never contains buy/sell/hold language and is identical for every user (ADR-011).
public struct InstrumentAssessment: Sendable, Equatable {
    public var statuses: [TriggeredStatus]
    public var argumentsFor: [Message]
    public var argumentsAgainst: [Message]
    public var pricedIn: [Message]
    public var invalidationConditions: [Message]
    public var missingData: [String]
    public var guidingQuestions: [Message]
    public var completeness: Double
}

public enum InstrumentAnalyzer {
    // Thresholds of FINANCIAL_METHODOLOGY §9 (education heuristics, not advice).
    static let highVolatility = 0.35
    static let deepDrawdown = 0.50
    static let highLeverage: Decimal = 2.0
    static let lowLeverage: Decimal = 0.5
    static let marginDropPoints: Decimal = 0.05
    static let highPE: Decimal = 30
    static let lowPE: Decimal = 10
    static let highPB: Decimal = 5
    static let strongMargin: Decimal = 0.15
    static let minimumCompleteness = 0.5

    /// The metrics a complete stock analysis needs (localisation key, value).
    static func stockMetrics(_ f: FundamentalsSnapshot?) -> [(String, Decimal?)] {
        [("metric.marketCap", f?.marketCapitalization), ("metric.revenue", f?.revenueTTM), ("metric.revenueGrowth", f?.revenueGrowthYoY),
         ("metric.netIncome", f?.netIncomeTTM), ("metric.eps", f?.epsTTM), ("metric.pe", f?.peRatio), ("metric.pb", f?.pbRatio),
         ("metric.fcf", f?.freeCashFlowTTM), ("metric.debtToEquity", f?.debtToEquity), ("metric.operatingMargin", f?.operatingMargin),
         ("metric.dividendYield", f?.dividendYield)]
    }

    public static func assessStock(fundamentals f: FundamentalsSnapshot?, series: PriceSeries?, isStale: Bool, isConflicting: Bool) -> InstrumentAssessment {
        let metrics = stockMetrics(f)
        let missing = metrics.filter { $0.1 == nil }.map(\.0)
        let completeness = Double(metrics.count - missing.count) / Double(metrics.count)
        let volatility = series.flatMap(Performance.annualizedVolatility)
        let drawdown = series.flatMap(Performance.maximumDrawdown)?.depth
        var statuses: [TriggeredStatus] = []
        var forArgs: [Message] = [], against: [Message] = [], pricedIn: [Message] = [], invalidation: [Message] = []

        if completeness < minimumCompleteness {
            statuses.append(TriggeredStatus(status: .insufficientData, rule: Message("rule.insufficientData", [.percent(completeness, fractionDigits: 0)])))
        }
        if let volatility, volatility > highVolatility {
            statuses.append(TriggeredStatus(status: .elevatedRisk, rule: Message("rule.highVolatility", [.percent(volatility, fractionDigits: 0)])))
        }
        if let drawdown, drawdown > deepDrawdown {
            statuses.append(TriggeredStatus(status: .elevatedRisk, rule: Message("rule.deepDrawdown", [.percent(drawdown, fractionDigits: 0)])))
        }
        if isConflicting { statuses.append(TriggeredStatus(status: .elevatedUncertainty, rule: Message("rule.conflictingSources"))) }
        if isStale { statuses.append(TriggeredStatus(status: .elevatedUncertainty, rule: Message("rule.staleData"))) }

        if let f {
            if let de = f.debtToEquity {
                if de > highLeverage { statuses.append(TriggeredStatus(status: .elevatedRisk, rule: Message("rule.highLeverage", [.decimal(de, fractionDigits: 2)]))) }
                if de > 1.5 { against.append(Message("thesis.against.leverage", [.decimal(de, fractionDigits: 2)])) }
                if de < lowLeverage { forArgs.append(Message("thesis.for.lowLeverage", [.decimal(de, fractionDigits: 2)])) }
                invalidation.append(Message("thesis.invalidation.leverage"))
            }
            if let eps = f.epsTTM, eps < 0 {
                statuses.append(TriggeredStatus(status: .elevatedUncertainty, rule: Message("rule.negativeEarnings")))
                against.append(Message("thesis.against.losses"))
            }
            if let growth = f.revenueGrowthYoY {
                if growth > 0 { forArgs.append(Message("thesis.for.revenueGrowth", [.percent(growth.doubleValue, fractionDigits: 1)])) }
                else { against.append(Message("thesis.against.revenueDecline", [.percent(growth.doubleValue, fractionDigits: 1)])) }
                invalidation.append(Message("thesis.invalidation.growth"))
            }
            if let margin = f.operatingMargin, margin > strongMargin {
                forArgs.append(Message("thesis.for.margin", [.percent(margin.doubleValue, fractionDigits: 1)]))
                invalidation.append(Message("thesis.invalidation.margin"))
            }
            if let fcf = f.freeCashFlowTTM {
                if fcf > 0 { forArgs.append(Message("thesis.for.cashFlow")) } else { against.append(Message("thesis.against.cashBurn")) }
            }
            if let pe = f.peRatio, (f.epsTTM ?? 1) > 0 {
                if pe > highPE { pricedIn.append(Message("thesis.pricedIn.high", [.decimal(pe, fractionDigits: 1)])) }
                if pe < lowPE { pricedIn.append(Message("thesis.pricedIn.low", [.decimal(pe, fractionDigits: 1)])) }
            }
            if let pb = f.pbRatio, pb > highPB { pricedIn.append(Message("thesis.pricedIn.highBook", [.decimal(pb, fractionDigits: 1)])) }
            if let dps = f.dividendPerShare, let eps = f.epsTTM, eps > 0, dps > eps {
                statuses.append(TriggeredStatus(status: .metricsWarrantReview, rule: Message("rule.payoutAboveEarnings")))
            }
            let statements = f.annualStatements.sorted { $0.fiscalYear < $1.fiscalYear }
            let fcfHistory = statements.compactMap { s -> Decimal? in
                guard let cfo = s.operatingCashFlow, let capex = s.capitalExpenditure else { return nil }
                return cfo - capex
            }
            if fcfHistory.count >= 2, fcfHistory.suffix(2).allSatisfy({ $0 < 0 }) {
                statuses.append(TriggeredStatus(status: .metricsWarrantReview, rule: Message("rule.negativeFCFTwoYears")))
            }
            let margins = statements.compactMap { s -> Decimal? in
                guard let revenue = s.revenue, revenue > 0, let op = s.operatingIncome else { return nil }
                return op / revenue
            }
            if margins.count >= 2, margins[margins.count - 2] - margins[margins.count - 1] > marginDropPoints {
                statuses.append(TriggeredStatus(status: .metricsWarrantReview, rule: Message("rule.marginDecline")))
            }
        }
        if let volatility, volatility > 0.3 { against.append(Message("thesis.against.volatility", [.percent(volatility, fractionDigits: 0)])) }
        if statuses.isEmpty { statuses.append(TriggeredStatus(status: .furtherResearchRequired, rule: Message("rule.default"))) }
        return InstrumentAssessment(statuses: statuses, argumentsFor: forArgs, argumentsAgainst: against, pricedIn: pricedIn,
                                    invalidationConditions: invalidation, missingData: missing,
                                    guidingQuestions: ["business", "revenue", "advantage", "risks", "management"].map { Message("thesis.question.\($0)") },
                                    completeness: completeness)
    }

    public struct BondAnalysis: Sendable, Equatable {
        public var yieldToMaturity: Double?
        public var currentYield: Double?
        public var accruedInterest: Double
        public var dirtyPrice: Double
        public var risk: BondMath.RiskMeasures?
        public var yieldToCall: Double?
        public var yearsToMaturity: Double
        public var priceChangeFor100bp: Double?
        public var isInvestmentGrade: Bool?
        public var statuses: [TriggeredStatus]
    }

    public static func analyzeBond(_ terms: BondDetails, cleanPrice: Double, settlement: LocalDate) -> BondAnalysis {
        let math = BondMath(terms: terms)
        let ytm = math.yieldToMaturity(clean: cleanPrice, settlement: settlement)
        let rating = terms.creditRating?.uppercased()
        let investmentGrade = rating.map { RiskEngine.investmentGrade.contains($0) }
        var statuses: [TriggeredStatus] = []
        if investmentGrade != true {
            statuses.append(TriggeredStatus(status: .elevatedRisk, rule: Message(rating == nil ? "rule.unratedBond" : "rule.belowInvestmentGrade")))
        }
        if statuses.isEmpty { statuses.append(TriggeredStatus(status: .furtherResearchRequired, rule: Message("rule.default"))) }
        return BondAnalysis(yieldToMaturity: ytm, currentYield: math.currentYield(clean: cleanPrice),
                            accruedInterest: math.accruedInterest(settlement: settlement),
                            dirtyPrice: math.dirtyPrice(clean: cleanPrice, settlement: settlement),
                            risk: ytm.flatMap { math.riskMeasures(yield: $0, settlement: settlement) },
                            yieldToCall: math.yieldToCall(clean: cleanPrice, settlement: settlement)?.yield,
                            yearsToMaturity: Double(settlement.days(to: terms.maturityDate)) / 365.25,
                            priceChangeFor100bp: math.cleanPriceChange(clean: cleanPrice, settlement: settlement, yieldShift: 0.01).map { $0 / cleanPrice },
                            isInvestmentGrade: investmentGrade, statuses: statuses)
    }

    public struct ETFAnalysis: Sendable, Equatable {
        /// Value of 10 000 after 10 years at an assumed 5 % gross return, with and without the TER (M-ETF).
        public var costDragExample: (withTER: Double, withoutTER: Double)?
        public var foreignCurrencyShare: Double?
        public var kidExpectation: Message
        public var statuses: [TriggeredStatus]

        public static func == (lhs: ETFAnalysis, rhs: ETFAnalysis) -> Bool {
            lhs.costDragExample?.withTER == rhs.costDragExample?.withTER && lhs.costDragExample?.withoutTER == rhs.costDragExample?.withoutTER
                && lhs.foreignCurrencyShare == rhs.foreignCurrencyShare && lhs.kidExpectation == rhs.kidExpectation && lhs.statuses == rhs.statuses
        }
    }

    static let euDomiciles: Set<String> = ["IE", "LU", "DE", "FR", "NL", "AT", "BE", "ES", "IT", "FI", "SE", "DK", "CZ", "PL", "PT"]

    public static func analyzeETF(_ etf: ETFDetails, baseCurrency: CurrencyCode) -> ETFAnalysis {
        let drag: (Double, Double)? = etf.totalExpenseRatio.map { ter in
            let gross = 0.05, years = 10.0, amount = 10_000.0
            return (amount * pow((1 + gross) * (1 - ter.doubleValue), years), amount * pow(1 + gross, years))
        }
        let foreign: Double? = etf.currencyExposure.isEmpty ? nil
            : etf.currencyExposure.filter { $0.label != baseCurrency.rawValue }.reduce(0) { $0 + $1.weight.doubleValue }
        let kid: Message
        switch (etf.isUCITS, etf.domicile.map { euDomiciles.contains($0) }) {
        case (true, _), (_, true): kid = Message("etf.kid.expected")
        case (false, false): kid = Message("etf.kid.nonEU")
        default: kid = Message("etf.kid.unknown")
        }
        var statuses: [TriggeredStatus] = []
        if etf.totalExpenseRatio == nil || etf.indexName == nil {
            statuses.append(TriggeredStatus(status: .insufficientData, rule: Message("rule.etfFactsMissing")))
        }
        if etf.replication == .synthetic { statuses.append(TriggeredStatus(status: .elevatedUncertainty, rule: Message("rule.syntheticReplication"))) }
        if statuses.isEmpty { statuses.append(TriggeredStatus(status: .furtherResearchRequired, rule: Message("rule.default"))) }
        return ETFAnalysis(costDragExample: drag, foreignCurrencyShare: foreign, kidExpectation: kid, statuses: statuses)
    }
}
