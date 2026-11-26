import Foundation

public enum AgeCategory: String, Codable, Sendable, CaseIterable {
    case under18, from18to25, from26to35, from36to50, from51to65, over65
    /// Minors use educational mode only (spec §7, §17, §19).
    public var isMinor: Bool { self == .under18 }
}

/// Knowledge is independent of risk capacity and must not determine acceptable risk (spec §7).
public enum KnowledgeLevel: String, Codable, Sendable, CaseIterable { case beginner, intermediate, advanced }

public enum FinancialGoal: String, Codable, Sendable, CaseIterable {
    case learning, emergencyFund, retirement, housing, education, wealthBuilding, other
}

public enum InvestmentHorizon: String, Codable, Sendable, CaseIterable {
    case underOneYear, oneToThreeYears, threeToTenYears, overTenYears
}

public enum IncomeStability: String, Codable, Sendable, CaseIterable { case stable, variable, irregular, noIncome }

public enum EmergencyFundStatus: String, Codable, Sendable, CaseIterable {
    case noFund, underThreeMonths, threeToSixMonths, overSixMonths
}

public enum DebtStatus: String, Codable, Sendable, CaseIterable {
    case noDebt, lowInterestOnly, highInterest, difficultyRepaying
}

public enum RiskAttitude: String, Codable, Sendable, CaseIterable {
    case avoidLosses, cautious, balanced, acceptsLargeSwings
}

public enum InvestmentExperience: String, Codable, Sendable, CaseIterable {
    case noExperience, savingsOnly, fundsOrETFs, stocksOrBonds, extensive
}

/// Local profile metadata (visible on the lock screen).
public struct UserProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: ProfileID
    public var displayName: String
    public var createdAt: Date
    public var ageCategory: AgeCategory?
    public var educationalMode: Bool

    public init(id: ProfileID = ProfileID(), displayName: String, createdAt: Date,
                ageCategory: AgeCategory? = nil, educationalMode: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.ageCategory = ageCategory
        self.educationalMode = educationalMode
    }
}

/// Onboarding answers. Used only for safety education and presentation — never to select, filter or
/// rank instruments (docs/LEGAL_COMPLIANCE.md §2).
public struct FinancialProfile: Hashable, Codable, Sendable {
    /// ISO 3166-1 alpha-2.
    public var country: String
    public var primaryCurrency: CurrencyCode
    public var ageCategory: AgeCategory
    public var knowledgeLevel: KnowledgeLevel
    public var goals: [FinancialGoal]
    public var horizon: InvestmentHorizon
    public var incomeStability: IncomeStability
    public var essentialMonthlyExpenses: Decimal?
    public var emergencyFund: EmergencyFundStatus
    public var debtStatus: DebtStatus
    public var riskAttitude: RiskAttitude
    public var experience: InvestmentExperience
    public var updatedAt: Date

    public init(country: String, primaryCurrency: CurrencyCode, ageCategory: AgeCategory, knowledgeLevel: KnowledgeLevel,
                goals: [FinancialGoal], horizon: InvestmentHorizon, incomeStability: IncomeStability,
                essentialMonthlyExpenses: Decimal?, emergencyFund: EmergencyFundStatus, debtStatus: DebtStatus,
                riskAttitude: RiskAttitude, experience: InvestmentExperience, updatedAt: Date) {
        self.country = country
        self.primaryCurrency = primaryCurrency
        self.ageCategory = ageCategory
        self.knowledgeLevel = knowledgeLevel
        self.goals = goals
        self.horizon = horizon
        self.incomeStability = incomeStability
        self.essentialMonthlyExpenses = essentialMonthlyExpenses
        self.emergencyFund = emergencyFund
        self.debtStatus = debtStatus
        self.riskAttitude = riskAttitude
        self.experience = experience
        self.updatedAt = updatedAt
    }

    public var isMinor: Bool { ageCategory.isMinor }
}

/// Safety observations derived from onboarding answers. They trigger *educational* notes only.
public enum SafetyNote: String, Codable, Sendable, CaseIterable, Hashable {
    case noEmergencyFund
    case smallEmergencyFund
    case highInterestDebt
    case debtDifficulty
    case shortHorizonVolatility
    case unstableIncome
    case educationalModeMinor
    case lossAversionVsVolatility

    public static func evaluate(_ profile: FinancialProfile) -> [SafetyNote] {
        var notes: [SafetyNote] = []
        if profile.isMinor { notes.append(.educationalModeMinor) }
        switch profile.emergencyFund {
        case .noFund: notes.append(.noEmergencyFund)
        case .underThreeMonths: notes.append(.smallEmergencyFund)
        default: break
        }
        switch profile.debtStatus {
        case .highInterest: notes.append(.highInterestDebt)
        case .difficultyRepaying: notes.append(.debtDifficulty)
        default: break
        }
        if profile.horizon == .underOneYear { notes.append(.shortHorizonVolatility) }
        if profile.incomeStability == .irregular || profile.incomeStability == .noIncome { notes.append(.unstableIncome) }
        if profile.riskAttitude == .avoidLosses { notes.append(.lossAversionVsVolatility) }
        return notes
    }
}
