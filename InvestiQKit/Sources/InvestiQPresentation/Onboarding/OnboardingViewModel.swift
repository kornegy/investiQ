import Foundation
import Observation
import InvestiQCore

/// Short onboarding questionnaire (spec §7). Collects only data needed for safety education and
/// presentation; never used to select or rank instruments (docs/LEGAL_COMPLIANCE.md §2).
@MainActor
@Observable
public final class OnboardingViewModel {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, residence, age, knowledge, goals, finances, risk, summary
    }

    /// Countries offered first; any ISO 3166 code is accepted.
    public static let featuredCountries = ["CZ", "SK", "DE", "AT", "PL", "HU", "UA", "NL", "FR", "IT", "ES", "IE", "GB", "US"]

    public var step: Step = .welcome
    public var country = "CZ"
    public var currency: CurrencyCode = .czk
    public var ageCategory: AgeCategory?
    public var knowledgeLevel: KnowledgeLevel?
    public var experience: InvestmentExperience?
    public var goals: Set<FinancialGoal> = []
    public var horizon: InvestmentHorizon?
    public var incomeStability: IncomeStability?
    public var essentialExpensesText = ""
    public var emergencyFund: EmergencyFundStatus?
    public var debtStatus: DebtStatus?
    public var riskAttitude: RiskAttitude?
    public private(set) var isSaving = false
    public private(set) var error: Message?

    private let app: AppModel
    private let systemLocale: Locale

    /// `locale` is used to read amounts while the system language is shown (no language picked).
    public init(app: AppModel, locale: Locale = .current) {
        self.app = app
        self.systemLocale = locale
    }

    /// Interface language picked on the first step (`nil` = system language). It is the same profile
    /// preference as Settings → General, so the choice stays after onboarding.
    public var languageOverride: String? { app.preferences.languageOverride }

    public func setLanguage(_ code: String?) async {
        guard code.map(UserPreferences.supportedLanguages.contains) ?? true else { return }
        do {
            try await app.updatePreferences { $0.languageOverride = code }
            error = nil
        } catch {
            self.error = Message("settings.error.saveFailed")
        }
    }

    /// Amounts are read in the language shown on screen.
    private var locale: Locale { languageOverride.map(Locale.init(identifier:)) ?? systemLocale }

    /// `nil` when empty; invalid text blocks the step (never silently becomes 0).
    public var essentialExpenses: Decimal? {
        let text = essentialExpensesText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return DecimalSupport.parse(text, locale: locale)
    }

    public var essentialExpensesInvalid: Bool {
        let text = essentialExpensesText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        guard let value = essentialExpenses else { return true }
        return value < 0
    }

    public var canAdvance: Bool {
        switch step {
        case .welcome: return true
        case .residence: return country.count == 2 && CurrencyCode.supportedBaseCurrencies.contains(currency)
        case .age: return ageCategory != nil
        case .knowledge: return knowledgeLevel != nil && experience != nil
        case .goals: return !goals.isEmpty && horizon != nil
        case .finances: return incomeStability != nil && emergencyFund != nil && debtStatus != nil && !essentialExpensesInvalid
        case .risk: return riskAttitude != nil
        case .summary: return draft != nil && !isSaving
        }
    }

    public var progress: Double { Double(step.rawValue) / Double(Step.allCases.count - 1) }

    public func next() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public var draft: FinancialProfile? {
        guard let ageCategory, let knowledgeLevel, let experience, let horizon, let incomeStability,
              let emergencyFund, let debtStatus, let riskAttitude, !goals.isEmpty, !essentialExpensesInvalid else { return nil }
        return FinancialProfile(country: country.uppercased(), primaryCurrency: currency, ageCategory: ageCategory,
                                knowledgeLevel: knowledgeLevel, goals: FinancialGoal.allCases.filter(goals.contains),
                                horizon: horizon, incomeStability: incomeStability,
                                essentialMonthlyExpenses: essentialExpenses, emergencyFund: emergencyFund,
                                debtStatus: debtStatus, riskAttitude: riskAttitude, experience: experience,
                                updatedAt: app.environment.clock.now())
    }

    /// Educational safety notes shown on the summary step.
    public var safetyNotes: [SafetyNote] { draft.map(SafetyNote.evaluate) ?? [] }

    public var willEnableEducationalMode: Bool { ageCategory?.isMinor == true }

    public func finish() async {
        guard let profile = draft else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.completeOnboarding(with: profile)
            error = nil
        } catch {
            self.error = Message("onboarding.error.saveFailed")
        }
    }
}
