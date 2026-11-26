import Foundation
import InvestiQCore

/// Planner budget (single row) and goals (docs/DATABASE_SCHEMA.md, planner_*).
public enum PlannerRecords {
    public static func budget(in db: SQLiteDatabase) throws -> BudgetInput? {
        guard let row = try db.queryOne("SELECT * FROM planner_budget WHERE id = 1") else { return nil }
        return BudgetInput(monthlyIncome: try row.optionalDecimal("monthly_income"),
                           essentialExpenses: try row.optionalDecimal("essential_expenses"),
                           additionalExpenses: try row.optionalDecimal("additional_expenses"),
                           debtPayments: try row.optionalDecimal("debt_payments"),
                           emergencyFund: try row.optionalDecimal("emergency_fund"),
                           availableSavings: try row.optionalDecimal("available_savings"),
                           currency: try row.currency("currency"))
    }

    public static func save(_ budget: BudgetInput, now: Date, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO planner_budget (id, monthly_income, essential_expenses, additional_expenses, debt_payments, emergency_fund,
                available_savings, currency, updated_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET monthly_income = excluded.monthly_income, essential_expenses = excluded.essential_expenses,
                additional_expenses = excluded.additional_expenses, debt_payments = excluded.debt_payments,
                emergency_fund = excluded.emergency_fund, available_savings = excluded.available_savings,
                currency = excluded.currency, updated_at = excluded.updated_at
            """, [.of(budget.monthlyIncome), .of(budget.essentialExpenses), .of(budget.additionalExpenses), .of(budget.debtPayments),
                  .of(budget.emergencyFund), .of(budget.availableSavings), .of(budget.currency), .of(now)])
    }

    public static func goals(in db: SQLiteDatabase) throws -> [PlannerGoal] {
        try db.query("SELECT * FROM planner_goals ORDER BY term DESC, target_date, name").map { row in
            guard let id = UUID(uuidString: try row.string("id")) else { throw SQLiteError.typeMismatch(column: "planner_goals.id") }
            return PlannerGoal(id: id, name: try row.string("name"), term: try row.enumValue("term"),
                               targetAmount: try row.decimal("target_amount"), currency: try row.currency("currency"),
                               targetDate: try row.optionalLocalDate("target_date"), createdAt: try row.instant("created_at"))
        }
    }

    public static func upsert(_ goal: PlannerGoal, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO planner_goals (id, name, term, target_amount, currency, target_date, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, term = excluded.term, target_amount = excluded.target_amount,
                currency = excluded.currency, target_date = excluded.target_date
            """, [.text(goal.id.uuidString), .text(goal.name), .of(goal.term), .of(goal.targetAmount), .of(goal.currency),
                  .of(goal.targetDate), .of(goal.createdAt)])
    }

    public static func deleteGoal(_ id: UUID, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM planner_goals WHERE id = ?", [.text(id.uuidString)])
    }
}
