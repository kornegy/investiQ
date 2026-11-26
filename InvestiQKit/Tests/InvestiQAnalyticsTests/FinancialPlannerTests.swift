import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class FinancialPlannerTests: XCTestCase {
    let budget = BudgetInput(monthlyIncome: 50_000, essentialExpenses: 25_000, additionalExpenses: 10_000, debtPayments: 5_000,
                             emergencyFund: 60_000, availableSavings: 30_000, currency: .czk)

    func testBudgetAnalysisHandChecked() {
        let analysis = FinancialPlanner.analyze(budget, debtStatus: .lowInterestOnly, isMinor: false)
        XCTAssertEqual(analysis.freeCashFlow, 10_000)                 // 50 000 − 40 000
        XCTAssertEqual(analysis.incomeToExpenseRatio, Decimal(string: "1.25"))
        XCTAssertEqual(analysis.emergencyCoverageMonths, 2)           // 60 000 / (25 000 + 5 000)
        XCTAssertEqual(analysis.notes, [.emergencyFundBelowThreeMonths])
    }

    func testMissingInputsStayMissing() {
        var partial = budget
        partial.additionalExpenses = nil
        let analysis = FinancialPlanner.analyze(partial, debtStatus: nil, isMinor: true)
        XCTAssertNil(analysis.freeCashFlow, "a blank field is not treated as zero")
        XCTAssertNil(analysis.incomeToExpenseRatio)
        XCTAssertEqual(analysis.emergencyCoverageMonths, 2)
        XCTAssertEqual(analysis.notes.first, .educationalModeOnly)
        XCTAssertNil(FinancialPlanner.incomeLoss(partial, reduction: 0.5))
    }

    func testNotesForNegativeCashFlowAndDebt() {
        var tight = budget
        tight.monthlyIncome = 39_000
        tight.emergencyFund = 0
        let analysis = FinancialPlanner.analyze(tight, debtStatus: .highInterest, isMinor: false)
        XCTAssertEqual(analysis.notes, [.negativeCashFlow, .noEmergencyFund, .highInterestDebt])
    }

    func testIncomeLossAndUnexpectedExpense() throws {
        let loss = try XCTUnwrap(FinancialPlanner.incomeLoss(budget, reduction: 0.5))
        XCTAssertEqual(loss.reducedIncome, 25_000)
        XCTAssertEqual(loss.monthlyBalance, -15_000)
        XCTAssertEqual(loss.monthsUntilReservesExhausted, 6)          // 90 000 / 15 000
        XCTAssertNil(try XCTUnwrap(FinancialPlanner.incomeLoss(budget, reduction: 0.1)).monthsUntilReservesExhausted)

        let shock = try XCTUnwrap(FinancialPlanner.unexpectedExpense(budget, amount: 100_000))
        XCTAssertEqual(shock.remainingReserves, 0)
        XCTAssertEqual(shock.shortfall, 10_000)
        XCTAssertEqual(shock.monthsToRebuild, 10)                     // 100 000 / 10 000
    }

    func testSavingsScenarioMatchesAnnuityFormula() throws {
        // 1 000 a month at 12 % a year (1 % a month): FV = 1 000 · (1.01^12 − 1)/0.01 = 12 682.50.
        let points = FinancialPlanner.savingsScenario(initial: 0, monthly: 1_000, annualReturn: Decimal(string: "0.12")!,
                                                      inflation: Decimal(string: "0.02")!, years: 2)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].contributed, 12_000)
        XCTAssertEqual(points[0].nominalValue, Decimal(string: "12682.50"))
        XCTAssertEqual(points[0].realValue, Decimal(string: "12433.83"))  // 12 682.503… / 1.02 (deflated before rounding)
        // Zero return: value equals contributions.
        let flat = FinancialPlanner.savingsScenario(initial: 5_000, monthly: 100, annualReturn: 0, inflation: 0, years: 3)
        XCTAssertEqual(flat.last?.nominalValue, 8_600)
    }

    func testPortfolioChangesAndGoal() throws {
        let changes = FinancialPlanner.portfolioValueChanges(value: 100_000, budget: budget)
        let drop = try XCTUnwrap(changes.first)
        XCTAssertEqual(drop.change, Decimal(string: "-0.4"))
        XCTAssertEqual(drop.newValue, 60_000)
        XCTAssertEqual(drop.monthsOfExpenses, Decimal(string: "1.3"))  // 40 000 / 30 000
        XCTAssertEqual(FinancialPlanner.monthlyAmountForGoal(target: 120_000, alreadySaved: 0, from: .d("2026-11-25"), to: .d("2027-11-01")),
                       10_000)
        XCTAssertNil(FinancialPlanner.monthlyAmountForGoal(target: 1, alreadySaved: 0, from: .d("2026-11-25"), to: .d("2026-11-30")))
    }
}
