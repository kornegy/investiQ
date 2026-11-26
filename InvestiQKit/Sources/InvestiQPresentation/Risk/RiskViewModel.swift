import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// Predefined hypothetical stress tests (FINANCIAL_METHODOLOGY §7, M-STR). Parameters are illustrative
/// assumptions, not predictions; no probability is attached to any of them.
public enum StressPreset: String, CaseIterable, Sendable, Identifiable {
    case equityMinus20, equityMinus40, ratesPlus1, ratesPlus2, ratesMinus1, inflation5For3Years,
         baseCurrencyPlus10, creditSpreadPlus2, largestIssuerDefault, largestIssuerMinus50
    public var id: String { rawValue }
    public var titleKey: String { "stress.preset.\(rawValue)" }
    /// Presets that need an issuer (the largest issuer exposure is used).
    public var needsIssuer: Bool { self == .largestIssuerDefault || self == .largestIssuerMinus50 }

    /// Recovery rate assumed for the issuer-default test (typical senior unsecured order of magnitude).
    public static let assumedRecoveryRate = 0.40

    func scenario(largestIssuer: String?) -> RiskEngine.StressScenario? {
        switch self {
        case .equityMinus20: return .equityDecline(0.20)
        case .equityMinus40: return .equityDecline(0.40)
        case .ratesPlus1: return .interestRateShift(0.01)
        case .ratesPlus2: return .interestRateShift(0.02)
        case .ratesMinus1: return .interestRateShift(-0.01)
        case .inflation5For3Years: return .inflation(annualRate: 0.05, years: 3)
        case .baseCurrencyPlus10: return .baseCurrencyAppreciation(0.10)
        case .creditSpreadPlus2: return .creditSpreadWidening(issuer: nil, spread: 0.02)
        case .largestIssuerDefault: return largestIssuer.map { .issuerDefault(issuer: $0, recoveryRate: Self.assumedRecoveryRate) }
        case .largestIssuerMinus50: return largestIssuer.map { .singleCompanyDecline(issuer: $0, decline: 0.50) }
        }
    }
}

public enum RiskTab: String, CaseIterable, Sendable, Identifiable {
    case categories, exposures, stress, forecasts
    public var id: String { rawValue }
    public var titleKey: String { "risk.tab.\(rawValue)" }
}

@MainActor
@Observable
public final class RiskViewModel {
    public private(set) var portfolios: [Portfolio] = []
    public var selectedPortfolioID: PortfolioID?
    public var tab: RiskTab = .categories
    public private(set) var assessment: PortfolioRiskAssessment?
    public private(set) var stressResults: [StressPreset: RiskEngine.StressResult] = [:]
    public private(set) var isLoading = false
    public private(set) var error: Message?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var baseCurrency: CurrencyCode { assessment?.baseCurrency ?? app.preferences.baseCurrency }
    public var report: PortfolioRiskReport? { assessment?.report }
    public var largestIssuer: ExposureItem? { report?.byIssuer.first }
    public var selectedPortfolio: Portfolio? { portfolios.first { $0.id == selectedPortfolioID } }

    public func load() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            portfolios = try await services.portfolios.portfolios()
            if selectedPortfolioID == nil || !portfolios.contains(where: { $0.id == selectedPortfolioID }) {
                selectedPortfolioID = portfolios.first(where: { $0.kind == .real })?.id ?? portfolios.first?.id
            }
            guard let id = selectedPortfolioID else { assessment = nil; stressResults = [:]; return }
            let result = try await services.risk.assess(id)
            assessment = result
            runStressTests(result)
            error = nil
        } catch {
            assessment = nil
            stressResults = [:]
            self.error = Message("risk.error.loadFailed")
        }
    }

    public func select(_ id: PortfolioID) async {
        selectedPortfolioID = id
        await load()
    }

    private func runStressTests(_ assessment: PortfolioRiskAssessment) {
        let engine = RiskEngine(baseCurrency: assessment.baseCurrency, settlement: app.environment.clock.today())
        var results: [StressPreset: RiskEngine.StressResult] = [:]
        for preset in StressPreset.allCases {
            guard let scenario = preset.scenario(largestIssuer: assessment.report.byIssuer.first?.label) else { continue }
            results[preset] = engine.stress(scenario, holdings: assessment.holdings, cashBase: assessment.cashBase)
        }
        stressResults = results
    }

    /// Categories ordered from the highest level down; unknown last.
    public var sortedCategories: [RiskCategoryAssessment] {
        (report?.categories ?? []).sorted { lhs, rhs in
            if lhs.level == .unknown { return false }
            if rhs.level == .unknown { return true }
            return lhs.level > rhs.level
        }
    }

    public var hasHoldings: Bool { !(assessment?.holdings.isEmpty ?? true) }
}
