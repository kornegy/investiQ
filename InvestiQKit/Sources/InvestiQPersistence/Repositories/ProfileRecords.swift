import Foundation
import InvestiQCore

/// Persistence of the profile row, preferences and onboarding answers (user database).
public enum ProfileRecords {
    public static func save(_ profile: UserProfile, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO user_profile (singleton, id, display_name, created_at, age_category, educational_mode)
            VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET display_name = excluded.display_name,
                age_category = excluded.age_category, educational_mode = excluded.educational_mode
            """, [.of(profile.id), .text(profile.displayName), .of(profile.createdAt), .of(profile.ageCategory),
                  .of(profile.educationalMode)])
    }

    public static func load(from db: SQLiteDatabase) throws -> UserProfile? {
        guard let row = try db.queryOne("SELECT * FROM user_profile WHERE singleton = 1") else { return nil }
        return UserProfile(id: try row.id("id"), displayName: try row.string("display_name"),
                           createdAt: try row.instant("created_at"), ageCategory: row.optionalEnum("age_category"),
                           educationalMode: try row.bool("educational_mode"))
    }
}

public enum PreferenceRecords {
    static let preferencesKey = "preferences.v1"

    public static func loadPreferences(from db: SQLiteDatabase) throws -> UserPreferences {
        guard let row = try db.queryOne("SELECT value FROM user_preferences WHERE key = ?", [.text(preferencesKey)]) else {
            return UserPreferences()
        }
        return try row.json("value", as: UserPreferences.self)
    }

    public static func savePreferences(_ preferences: UserPreferences, in db: SQLiteDatabase) throws {
        try db.run("INSERT INTO user_preferences (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(preferencesKey), try .json(preferences)])
    }
}

public enum FinancialProfileRecords {
    public static func save(_ p: FinancialProfile, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO financial_profile (id, country, primary_currency, age_category, knowledge_level, goals, horizon,
                income_stability, essential_monthly_expenses, emergency_fund, debt_status, risk_attitude, experience, updated_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET country = excluded.country, primary_currency = excluded.primary_currency,
                age_category = excluded.age_category, knowledge_level = excluded.knowledge_level, goals = excluded.goals,
                horizon = excluded.horizon, income_stability = excluded.income_stability,
                essential_monthly_expenses = excluded.essential_monthly_expenses, emergency_fund = excluded.emergency_fund,
                debt_status = excluded.debt_status, risk_attitude = excluded.risk_attitude,
                experience = excluded.experience, updated_at = excluded.updated_at
            """, [.text(p.country), .of(p.primaryCurrency), .of(p.ageCategory), .of(p.knowledgeLevel), try .json(p.goals),
                  .of(p.horizon), .of(p.incomeStability), .of(p.essentialMonthlyExpenses), .of(p.emergencyFund),
                  .of(p.debtStatus), .of(p.riskAttitude), .of(p.experience), .of(p.updatedAt)])
    }

    public static func load(from db: SQLiteDatabase) throws -> FinancialProfile? {
        guard let row = try db.queryOne("SELECT * FROM financial_profile WHERE id = 1") else { return nil }
        return FinancialProfile(
            country: try row.string("country"), primaryCurrency: try row.currency("primary_currency"),
            ageCategory: try row.enumValue("age_category"), knowledgeLevel: try row.enumValue("knowledge_level"),
            goals: try row.json("goals"), horizon: try row.enumValue("horizon"),
            incomeStability: try row.enumValue("income_stability"),
            essentialMonthlyExpenses: try row.optionalDecimal("essential_monthly_expenses"),
            emergencyFund: try row.enumValue("emergency_fund"), debtStatus: try row.enumValue("debt_status"),
            riskAttitude: try row.enumValue("risk_attitude"), experience: try row.enumValue("experience"),
            updatedAt: try row.instant("updated_at"))
    }
}
