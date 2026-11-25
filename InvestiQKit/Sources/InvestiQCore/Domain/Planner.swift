import Foundation

/// Monthly budget entered by the user. Fields stay `nil` until entered (never assumed to be zero).
public struct BudgetInput: Sendable, Equatable, Codable {
    public var monthlyIncome: Decimal?
    public var essentialExpenses: Decimal?
    public var additionalExpenses: Decimal?
    public var debtPayments: Decimal?
    public var emergencyFund: Decimal?
    public var availableSavings: Decimal?
    public var currency: CurrencyCode

    public init(monthlyIncome: Decimal? = nil, essentialExpenses: Decimal? = nil, additionalExpenses: Decimal? = nil,
                debtPayments: Decimal? = nil, emergencyFund: Decimal? = nil, availableSavings: Decimal? = nil, currency: CurrencyCode) {
        self.monthlyIncome = monthlyIncome; self.essentialExpenses = essentialExpenses; self.additionalExpenses = additionalExpenses
        self.debtPayments = debtPayments; self.emergencyFund = emergencyFund; self.availableSavings = availableSavings
        self.currency = currency
    }

    /// Essential expenses + debt payments: what must be paid every month.
    public var obligatoryOutflow: Decimal? {
        guard let essentialExpenses, let debtPayments else { return nil }
        return essentialExpenses + debtPayments
    }

    public var totalOutflow: Decimal? {
        guard let obligatoryOutflow, let additionalExpenses else { return nil }
        return obligatoryOutflow + additionalExpenses
    }
}

/// A user-defined financial goal.
public struct PlannerGoal: Sendable, Hashable, Identifiable, Codable {
    public enum Term: String, Sendable, Codable, CaseIterable { case short, long }
    public var id: UUID
    public var name: String
    public var term: Term
    public var targetAmount: Decimal
    public var currency: CurrencyCode
    public var targetDate: LocalDate?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, term: Term, targetAmount: Decimal, currency: CurrencyCode, targetDate: LocalDate?, createdAt: Date) {
        self.id = id; self.name = name; self.term = term; self.targetAmount = targetAmount; self.currency = currency
        self.targetDate = targetDate; self.createdAt = createdAt
    }
}

/// Progress through one lesson (learning_progress table).
public struct LessonProgress: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable, CaseIterable { case notStarted, inProgress, completed }
    public var lessonID: String
    public var status: Status
    public var quizBestScore: Int?
    public var quizAttempts: Int
    public var updatedAt: Date

    public init(lessonID: String, status: Status, quizBestScore: Int?, quizAttempts: Int, updatedAt: Date) {
        self.lessonID = lessonID; self.status = status; self.quizBestScore = quizBestScore; self.quizAttempts = quizAttempts
        self.updatedAt = updatedAt
    }
}
