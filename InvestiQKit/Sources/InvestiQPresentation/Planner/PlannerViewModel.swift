import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// Financial planner (spec §17, M-PLAN). Never proposes an investment amount and never uses age,
/// experience or knowledge to size anything; all scenario amounts are chosen by the user.
@MainActor
@Observable
public final class PlannerViewModel {
    public enum Field: String, CaseIterable, Sendable, Identifiable {
        case monthlyIncome, essentialExpenses, additionalExpenses, debtPayments, emergencyFund, availableSavings
        public var id: String { rawValue }
        public var labelKey: String { "planner.field.\(rawValue)" }
    }

    public var texts: [Field: String] = [:]
    public private(set) var currency: CurrencyCode
    public private(set) var analysis: BudgetAnalysis?
    public private(set) var invalidField: Field?
    public private(set) var goals: [PlannerGoal] = []
    public private(set) var error: Message?
    public private(set) var saved = false

    // Scenario inputs (user-chosen).
    public var incomeLossPercent: Decimal = 50
    public var unexpectedExpense: Decimal = 20_000
    public var savingsInitial: Decimal = 0
    public var savingsMonthly: Decimal = 1_000
    public var savingsReturnPercent: Decimal = 3
    public var inflationPercent: Decimal = 2.5
    public var savingsYears = 10
    public var portfolioValue: Decimal = 100_000

    private let app: AppModel
    private let locale: Locale
    private var debtStatus: DebtStatus?

    public init(app: AppModel, locale: Locale = .current) {
        self.app = app
        self.locale = locale
        currency = app.preferences.baseCurrency
    }

    public var isMinor: Bool { app.educationalMode }

    public func load() async {
        guard let services = app.services else { return }
        do {
            debtStatus = try await services.profileData.financialProfile()?.debtStatus
            if let budget = try await services.planner.budget() {
                currency = budget.currency
                fill(from: budget)
            }
            goals = try await services.planner.goals()
            recompute()
            error = nil
        } catch {
            self.error = Message("planner.error.loadFailed")
        }
    }

    private func fill(from budget: BudgetInput) {
        func text(_ value: Decimal?) -> String { value.map { $0.formatted(.number.locale(locale).grouping(.never)) } ?? "" }
        texts[.monthlyIncome] = text(budget.monthlyIncome)
        texts[.essentialExpenses] = text(budget.essentialExpenses)
        texts[.additionalExpenses] = text(budget.additionalExpenses)
        texts[.debtPayments] = text(budget.debtPayments)
        texts[.emergencyFund] = text(budget.emergencyFund)
        texts[.availableSavings] = text(budget.availableSavings)
    }

    /// Parses the fields; blank stays `nil`, invalid or negative input marks the field.
    public var budget: BudgetInput? {
        var values: [Field: Decimal] = [:]
        for field in Field.allCases {
            let text = (texts[field] ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let value = DecimalSupport.parse(text, locale: locale), value >= 0 else { return nil }
            values[field] = value
        }
        return BudgetInput(monthlyIncome: values[.monthlyIncome], essentialExpenses: values[.essentialExpenses],
                           additionalExpenses: values[.additionalExpenses], debtPayments: values[.debtPayments],
                           emergencyFund: values[.emergencyFund], availableSavings: values[.availableSavings], currency: currency)
    }

    public func recompute() {
        invalidField = Field.allCases.first { field in
            let text = (texts[field] ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            guard let value = DecimalSupport.parse(text, locale: locale) else { return true }
            return value < 0
        }
        guard invalidField == nil, let budget else { analysis = nil; return }
        analysis = FinancialPlanner.analyze(budget, debtStatus: debtStatus, isMinor: isMinor)
    }

    public func save() async {
        recompute()
        guard let services = app.services, let budget, invalidField == nil else { return }
        do {
            try await services.planner.save(budget)
            saved = true
            error = nil
        } catch {
            self.error = Message("planner.error.saveFailed")
        }
    }

    // MARK: Scenarios

    public var incomeLoss: IncomeLossResult? {
        budget.flatMap { FinancialPlanner.incomeLoss($0, reduction: incomeLossPercent / 100) }
    }

    public var unexpectedExpenseResult: UnexpectedExpenseResult? {
        budget.flatMap { FinancialPlanner.unexpectedExpense($0, amount: unexpectedExpense) }
    }

    public var savings: [SavingsPoint] {
        FinancialPlanner.savingsScenario(initial: savingsInitial, monthly: savingsMonthly, annualReturn: savingsReturnPercent / 100,
                                         inflation: inflationPercent / 100, years: savingsYears)
    }

    /// The same contributions without any return, for comparison.
    public var savingsWithoutReturn: [SavingsPoint] {
        FinancialPlanner.savingsScenario(initial: savingsInitial, monthly: savingsMonthly, annualReturn: 0,
                                         inflation: inflationPercent / 100, years: savingsYears)
    }

    public var portfolioChanges: [PortfolioChangeScenario] {
        FinancialPlanner.portfolioValueChanges(value: portfolioValue, budget: budget ?? BudgetInput(currency: currency))
    }

    // MARK: Goals

    public func addGoal(name: String, term: PlannerGoal.Term, amountText: String, targetDate: LocalDate?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services = app.services, (1...100).contains(trimmed.count),
              let amount = DecimalSupport.parse(amountText.trimmingCharacters(in: .whitespaces), locale: locale), amount > 0 else {
            error = Message("planner.error.invalidGoal")
            return false
        }
        let goal = PlannerGoal(name: trimmed, term: term, targetAmount: amount, currency: currency, targetDate: targetDate,
                               createdAt: app.environment.clock.now())
        do {
            try await services.planner.save(goal)
            goals = try await services.planner.goals()
            error = nil
            return true
        } catch {
            self.error = Message("planner.error.saveFailed")
            return false
        }
    }

    public func deleteGoal(_ goal: PlannerGoal) async {
        guard let services = app.services else { return }
        do {
            try await services.planner.deleteGoal(goal.id)
            goals = try await services.planner.goals()
        } catch {
            self.error = Message("planner.error.saveFailed")
        }
    }

    /// Monthly amount to reach the goal by its date with no assumed return (already-saved amounts are not
    /// allocated to goals automatically).
    public func monthlyAmount(for goal: PlannerGoal) -> Decimal? {
        guard let date = goal.targetDate else { return nil }
        return FinancialPlanner.monthlyAmountForGoal(target: goal.targetAmount, alreadySaved: 0, from: app.environment.clock.today(), to: date)
    }
}
