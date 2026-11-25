import Foundation
import InvestiQCore

/// Educational notes (FINANCIAL_METHODOLOGY §10). They explain; they never suggest an amount to invest.
public enum PlannerNote: String, Sendable, Hashable, CaseIterable {
    case negativeCashFlow, noEmergencyFund, emergencyFundBelowThreeMonths, highInterestDebt, debtDifficulty, educationalModeOnly
    public var messageKey: String { "planner.note.\(rawValue)" }
}

public struct BudgetAnalysis: Sendable, Equatable {
    public var freeCashFlow: Decimal?
    public var incomeToExpenseRatio: Decimal?
    /// Months the emergency fund covers essential expenses and debt payments.
    public var emergencyCoverageMonths: Decimal?
    public var notes: [PlannerNote]
}

public struct IncomeLossResult: Sendable, Equatable {
    public var reducedIncome: Decimal
    public var monthlyBalance: Decimal
    /// Months until the emergency fund and savings are used up; `nil` when the balance stays ≥ 0.
    public var monthsUntilReservesExhausted: Decimal?
}

public struct UnexpectedExpenseResult: Sendable, Equatable {
    public var remainingReserves: Decimal
    /// Shortfall not covered by reserves (0 when fully covered).
    public var shortfall: Decimal
    /// Months of free cash flow needed to rebuild the amount; `nil` when free cash flow ≤ 0.
    public var monthsToRebuild: Decimal?
}

public struct SavingsPoint: Sendable, Equatable, Identifiable {
    public var year: Int
    public var contributed: Decimal
    public var nominalValue: Decimal
    /// Value in today's money (deflated by the assumed inflation).
    public var realValue: Decimal
    public var id: Int { year }
}

public struct PortfolioChangeScenario: Sendable, Equatable, Identifiable {
    public var change: Decimal
    public var newValue: Decimal
    public var difference: Decimal
    /// |difference| expressed in months of obligatory outflow, when known.
    public var monthsOfExpenses: Decimal?
    public var id: Decimal { change }
}

/// Planner calculations (M-PLAN). Decimal throughout; no figure depends on age, experience or knowledge.
public enum FinancialPlanner {
    /// Coverage below this many months triggers the emergency-fund note (common guidance: 3–6 months).
    public static let minimumEmergencyMonths: Decimal = 3
    public static let monthsPerYear = 12
    /// Illustrative portfolio moves shown in the value-change scenarios (hypothetical).
    public static let portfolioChanges: [Decimal] = [-0.4, -0.2, -0.1, 0.1, 0.2]

    public static func analyze(_ budget: BudgetInput, debtStatus: DebtStatus?, isMinor: Bool) -> BudgetAnalysis {
        var freeCashFlow: Decimal?
        var ratio: Decimal?
        if let income = budget.monthlyIncome, let outflow = budget.totalOutflow {
            freeCashFlow = income - outflow
            ratio = outflow > 0 ? (income / outflow).rounded(scale: 2) : nil
        }
        var coverage: Decimal?
        if let fund = budget.emergencyFund, let obligatory = budget.obligatoryOutflow, obligatory > 0 {
            coverage = (fund / obligatory).rounded(scale: 1)
        }
        var notes: [PlannerNote] = []
        if isMinor { notes.append(.educationalModeOnly) }
        if let freeCashFlow, freeCashFlow <= 0 { notes.append(.negativeCashFlow) }
        if let fund = budget.emergencyFund, fund <= 0 { notes.append(.noEmergencyFund) }
        else if let coverage, coverage < minimumEmergencyMonths { notes.append(.emergencyFundBelowThreeMonths) }
        if debtStatus == .highInterest { notes.append(.highInterestDebt) }
        if debtStatus == .difficultyRepaying { notes.append(.debtDifficulty) }
        return BudgetAnalysis(freeCashFlow: freeCashFlow, incomeToExpenseRatio: ratio, emergencyCoverageMonths: coverage, notes: notes)
    }

    /// Income reduced by `reduction` (0.5 = −50 %) while all expenses continue.
    public static func incomeLoss(_ budget: BudgetInput, reduction: Decimal) -> IncomeLossResult? {
        guard let income = budget.monthlyIncome, let outflow = budget.totalOutflow, reduction >= 0, reduction <= 1 else { return nil }
        let reduced = income * (1 - reduction)
        let balance = reduced - outflow
        var months: Decimal?
        if balance < 0 {
            let reserves = (budget.emergencyFund ?? 0) + (budget.availableSavings ?? 0)
            months = (reserves / -balance).rounded(scale: 1)
        }
        return IncomeLossResult(reducedIncome: reduced, monthlyBalance: balance, monthsUntilReservesExhausted: months)
    }

    /// One-off expense paid from the emergency fund first, then from savings.
    public static func unexpectedExpense(_ budget: BudgetInput, amount: Decimal) -> UnexpectedExpenseResult? {
        guard amount >= 0, budget.emergencyFund != nil || budget.availableSavings != nil else { return nil }
        let reserves = (budget.emergencyFund ?? 0) + (budget.availableSavings ?? 0)
        let remaining = max(0, reserves - amount)
        let shortfall = max(0, amount - reserves)
        var months: Decimal?
        if let income = budget.monthlyIncome, let outflow = budget.totalOutflow, income - outflow > 0 {
            months = (amount / (income - outflow)).rounded(scale: 1)
        }
        return UnexpectedExpenseResult(remainingReserves: remaining, shortfall: shortfall, monthsToRebuild: months)
    }

    /// `FV = PV(1+i)^n + PMT·((1+i)^n − 1)/i` with monthly `i = r/12`; contributions at month end.
    /// `annualReturn` and `inflation` are user-chosen assumptions, not expectations.
    public static func savingsScenario(initial: Decimal, monthly: Decimal, annualReturn: Decimal, inflation: Decimal,
                                       years: Int) -> [SavingsPoint] {
        guard years > 0, initial >= 0, monthly >= 0 else { return [] }
        let i = annualReturn / Decimal(monthsPerYear)
        var points: [SavingsPoint] = []
        for year in 1...years {
            let n = year * monthsPerYear
            let growth = pow(1 + i, n)
            let annuity = i == 0 ? Decimal(n) : (growth - 1) / i
            let nominal = initial * growth + monthly * annuity
            let real = nominal / pow(1 + inflation, year)
            points.append(SavingsPoint(year: year, contributed: initial + monthly * Decimal(n),
                                       nominalValue: nominal.rounded(scale: 2), realValue: real.rounded(scale: 2)))
        }
        return points
    }

    /// Hypothetical moves of a portfolio value, also expressed in months of obligatory outflow.
    public static func portfolioValueChanges(value: Decimal, budget: BudgetInput) -> [PortfolioChangeScenario] {
        portfolioChanges.map { change in
            let difference = (value * change).rounded(scale: 2)
            let months = budget.obligatoryOutflow.flatMap { $0 > 0 ? (abs(difference) / $0).rounded(scale: 1) : nil }
            return PortfolioChangeScenario(change: change, newValue: value + difference, difference: difference, monthsOfExpenses: months)
        }
    }

    /// Monthly amount needed to reach a goal by its date without assuming any return (`nil` if the date has passed).
    public static func monthlyAmountForGoal(target: Decimal, alreadySaved: Decimal, from today: LocalDate, to date: LocalDate) -> Decimal? {
        let months = (date.year - today.year) * monthsPerYear + (date.month - today.month)
        guard months > 0 else { return nil }
        return (max(0, target - alreadySaved) / Decimal(months)).rounded(scale: 2)
    }
}
