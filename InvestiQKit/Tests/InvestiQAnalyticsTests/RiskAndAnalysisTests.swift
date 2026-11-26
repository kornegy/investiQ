import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class RiskAndAnalysisTests: XCTestCase {
    let engine = RiskEngine(baseCurrency: .czk, settlement: .d("2026-06-01"))

    func holding(_ name: String, _ kind: InstrumentKind = .stock, value: Double, currency: CurrencyCode = .czk, country: String = "CZ",
                 sector: String = "Utilities", beta: Double? = nil, bond: BondDetails? = nil, price: Double? = nil, etf: ETFDetails? = nil) -> RiskHolding {
        RiskHolding(id: name, name: name, kind: kind, valueBase: value, currency: currency, country: country, sector: sector, issuer: name,
                    beta: beta, bond: bond, bondCleanPrice: price, etf: etf)
    }

    func testConcentrationAndExposures() {
        let report = engine.report(holdings: [holding("A", value: 600), holding("B", value: 300, sector: "Tech"), holding("C", value: 100, sector: "Tech")],
                                   cashBase: 0, portfolioDailyReturns: [])
        // HHI = 0.36 + 0.09 + 0.01 = 0.46; effective number of positions ≈ 2.17.
        XCTAssertEqual(report.herfindahl!, 0.46, accuracy: 1e-12)
        XCTAssertEqual(report.effectivePositions!, 1 / 0.46, accuracy: 1e-12)
        XCTAssertEqual(report.bySector.first { $0.label == "Tech" }!.weight, 0.4, accuracy: 1e-12)
        XCTAssertEqual(report.categories.first { $0.category == .concentration }?.level, .high)
        XCTAssertEqual(report.categories.first { $0.category == .market }?.level, .unknown, "no return history → unknown, not low")
    }

    func testCurrencyLookThroughForETFs() {
        let etf = ETFDetails(currencyExposure: [WeightedItem(label: "USD", weight: 0.7), WeightedItem(label: "EUR", weight: 0.3)])
        let report = engine.report(holdings: [holding("World", .etf, value: 1_000, currency: .eur, etf: etf)], cashBase: 0, portfolioDailyReturns: [])
        XCTAssertEqual(report.byCurrency.first { $0.label == "USD" }!.weight, 0.7, accuracy: 1e-12, "exposure follows the fund's assets, not its trading currency")
        XCTAssertEqual(report.categories.first { $0.category == .currency }?.level, .high)
    }

    func testVaRIsLabelledAndNeedsHistory() {
        var returns = Array(repeating: 0.001, count: 300)
        for i in stride(from: 0, to: 300, by: 15) { returns[i] = -0.03 } // 20 bad days of −3 % (6.7 % of days)
        let report = engine.report(holdings: [holding("A", value: 1_000)], cashBase: 0, portfolioDailyReturns: returns)
        XCTAssertEqual(report.valueAtRisk95!, 0.03, accuracy: 1e-9)
        XCTAssertEqual(report.conditionalVaR95!, 0.03, accuracy: 1e-9)
        XCTAssertNil(engine.report(holdings: [holding("A", value: 1)], cashBase: 0, portfolioDailyReturns: Array(returns.prefix(100))).valueAtRisk95)
    }

    func testStressTests() throws {
        let bond = BondDetails(issuerType: .corporate, faceValue: 1_000, couponRate: 0.05, couponFrequency: 1, dayCount: .actualActualICMA,
                               issueDate: .d("2021-06-01"), maturityDate: .d("2031-06-01"), creditRating: "BB")
        let holdings = [holding("Stock", value: 1_000, beta: 1.5), holding("Plain", value: 1_000),
                        holding("Bond", .corporateBond, value: 1_000, bond: bond, price: 100),
                        holding("US", value: 1_000, currency: .usd, country: "US")]
        // Equity −20 %: 1 000 × 0.2 × 1.5 + 1 000 × 0.2 × 1 (assumed beta) + 1 000 × 0.2 (US stock) = 700 loss.
        let equity = engine.stress(.equityDecline(0.2), holdings: holdings, cashBase: 0)
        XCTAssertEqual(equity.changeBase, -700, accuracy: 1e-9)
        XCTAssertTrue(equity.lines.contains { $0.name == "Plain" && $0.usedAssumption })
        XCTAssertTrue(equity.assumptions.contains(Message("stress.hypothetical")))
        let rates = engine.stress(.interestRateShift(0.01), holdings: holdings, cashBase: 0)
        XCTAssertLessThan(rates.changeBase, 0)
        XCTAssertEqual(rates.lines.count, 1)
        let fx = engine.stress(.baseCurrencyAppreciation(0.1), holdings: holdings, cashBase: 0)
        XCTAssertEqual(fx.changeBase, -100, accuracy: 1e-9)
        let defaulted = engine.stress(.issuerDefault(issuer: "Bond", recoveryRate: 0.4), holdings: holdings, cashBase: 0)
        XCTAssertEqual(defaulted.changeBase, -600, accuracy: 1e-9)
        let inflation = engine.stress(.inflation(annualRate: 0.05, years: 2), holdings: holdings, cashBase: 1_000)
        XCTAssertEqual(inflation.changeBase, -2_000 * (1 - 1 / 1.1025), accuracy: 1e-9)
        let report = engine.report(holdings: holdings, cashBase: 0, portfolioDailyReturns: [])
        XCTAssertEqual(report.categories.first { $0.category == .credit }?.level, .elevated, "25 % below investment grade")
        XCTAssertGreaterThan(report.weightedModifiedDuration ?? 0, 0)
    }

    func testStockAssessmentIsNeutralAndRuleBased() {
        let weak = FundamentalsSnapshot(revenueGrowthYoY: -0.1, netIncomeTTM: -5, epsTTM: -1, freeCashFlowTTM: -3, debtToEquity: 2.6)
        let assessment = InstrumentAnalyzer.assessStock(fundamentals: weak, series: nil, isStale: false, isConflicting: false)
        let statuses = Set(assessment.statuses.map(\.status))
        XCTAssertTrue(statuses.contains(.elevatedRisk))
        XCTAssertTrue(statuses.contains(.elevatedUncertainty))
        XCTAssertTrue(statuses.contains(.insufficientData))
        XCTAssertFalse(assessment.argumentsAgainst.isEmpty)
        XCTAssertTrue(assessment.missingData.contains("metric.pe"))
        XCTAssertFalse(assessment.guidingQuestions.isEmpty)
        // Every rule key is a neutral analytical status; no buy/sell vocabulary exists in the type.
        XCTAssertTrue(assessment.statuses.allSatisfy { AnalyticalStatus.allCases.contains($0.status) })

        let complete = FundamentalsSnapshot(marketCapitalization: 1, revenueTTM: 1, revenueGrowthYoY: 0.05, netIncomeTTM: 1, epsTTM: 1,
                                            peRatio: 15, pbRatio: 2, freeCashFlowTTM: 1, debtToEquity: 0.3, operatingMargin: 0.2,
                                            dividendYield: 0.02)
        let healthy = InstrumentAnalyzer.assessStock(fundamentals: complete, series: nil, isStale: false, isConflicting: false)
        XCTAssertEqual(healthy.statuses.map(\.status), [.furtherResearchRequired], "default status when no rule fires")
        XCTAssertEqual(healthy.completeness, 1)
        XCTAssertFalse(healthy.argumentsFor.isEmpty)
    }

    func testMetricsWarrantReviewFromStatements() {
        let statements = [
            FinancialStatementPeriod(fiscalYear: 2024, periodEnd: .d("2024-12-31"), revenue: 100, operatingIncome: 20, operatingCashFlow: 5, capitalExpenditure: 10),
            FinancialStatementPeriod(fiscalYear: 2025, periodEnd: .d("2025-12-31"), revenue: 100, operatingIncome: 10, operatingCashFlow: 5, capitalExpenditure: 12),
        ]
        let f = FundamentalsSnapshot(annualStatements: statements)
        let assessment = InstrumentAnalyzer.assessStock(fundamentals: f, series: nil, isStale: true, isConflicting: true)
        let rules = assessment.statuses.map(\.rule.key)
        XCTAssertTrue(rules.contains("rule.negativeFCFTwoYears"))
        XCTAssertTrue(rules.contains("rule.marginDecline"))
        XCTAssertTrue(rules.contains("rule.staleData"))
        XCTAssertTrue(rules.contains("rule.conflictingSources"))
    }

    func testBondAndETFAnalysis() throws {
        let bond = BondDetails(issuerType: .government, faceValue: 10_000, couponRate: 0.045, couponFrequency: 1, dayCount: .actualActualICMA,
                               issueDate: .d("2020-11-11"), maturityDate: .d("2030-11-11"), creditRating: "AA-")
        let analysis = InstrumentAnalyzer.analyzeBond(bond, cleanPrice: 101.2, settlement: .d("2026-06-01"))
        XCTAssertLessThan(try XCTUnwrap(analysis.yieldToMaturity), 0.045, "a premium price yields less than the coupon")
        XCTAssertEqual(analysis.isInvestmentGrade, true)
        XCTAssertEqual(analysis.statuses.map(\.status), [.furtherResearchRequired])
        XCTAssertLessThan(try XCTUnwrap(analysis.priceChangeFor100bp), 0)
        let unrated = BondDetails(issuerType: .corporate, faceValue: 1_000, couponRate: 0.08, couponFrequency: 1, dayCount: .thirtyE360,
                                  maturityDate: .d("2029-01-01"))
        XCTAssertEqual(InstrumentAnalyzer.analyzeBond(unrated, cleanPrice: 95, settlement: .d("2026-06-01")).statuses.first?.rule.key, "rule.unratedBond")

        let etf = ETFDetails(indexName: "World", totalExpenseRatio: 0.002, replication: .synthetic, isUCITS: true, domicile: "IE",
                             currencyExposure: [WeightedItem(label: "USD", weight: 0.7), WeightedItem(label: "CZK", weight: 0.3)])
        let etfAnalysis = InstrumentAnalyzer.analyzeETF(etf, baseCurrency: .czk)
        let drag = try XCTUnwrap(etfAnalysis.costDragExample)
        XCTAssertEqual(drag.withoutTER, 10_000 * pow(1.05, 10), accuracy: 1e-6)
        XCTAssertEqual(drag.withTER, 10_000 * pow(1.05 * 0.998, 10), accuracy: 1e-6)
        XCTAssertEqual(etfAnalysis.foreignCurrencyShare!, 0.7, accuracy: 1e-12)
        XCTAssertEqual(etfAnalysis.kidExpectation, Message("etf.kid.expected"))
        XCTAssertTrue(etfAnalysis.statuses.contains { $0.rule.key == "rule.syntheticReplication" })
        let us = ETFDetails(indexName: "S&P", totalExpenseRatio: 0.0003, isUCITS: false, domicile: "US")
        XCTAssertEqual(InstrumentAnalyzer.analyzeETF(us, baseCurrency: .czk).kidExpectation, Message("etf.kid.nonEU"))
    }
}
