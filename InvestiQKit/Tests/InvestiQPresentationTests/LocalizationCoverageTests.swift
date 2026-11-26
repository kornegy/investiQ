import XCTest
@testable import InvestiQPresentation
import InvestiQAnalytics
import InvestiQContent
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

/// The app turns enum values into localisation keys at run time (`L10n.key("news.type", type.rawValue)`).
/// A case without an en/ru/cs entry would put the raw key on screen, so every case of every such
/// family must be in `Localization/*.json`. Adding an enum case without translations fails here.
@MainActor
final class LocalizationCoverageTests: XCTestCase {
    private static let languages = ["en", "ru", "cs"]

    /// `Localization/` at the repository root; the Linux test container mounts it and sets the variable.
    private static func localizationDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["INVESTIQ_LOCALIZATION_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InvestiQPresentationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // InvestiQKit
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Localization", isDirectory: true)
    }

    private func loadCatalog() throws -> [String: [String: String]] {
        let directory = Self.localizationDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty, "no catalog files in \(directory.path)")
        var catalog: [String: [String: String]] = [:]
        for file in files {
            let entries = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))
            catalog.merge(entries) { current, _ in current }
        }
        return catalog
    }

    private static func values<T: CaseIterable & RawRepresentable>(_: T.Type) -> [String] where T.RawValue == String {
        T.allCases.map(\.rawValue)
    }

    /// (key template with `*` for the run-time value, values) — mirrors the `L10n.key` / `L10n.string`
    /// call sites in the app target.
    private static let families: [(template: String, values: [String])] = [
        ("onboarding.age.*", values(AgeCategory.self)),
        ("onboarding.knowledge.*", values(KnowledgeLevel.self)),
        ("onboarding.experience.*", values(InvestmentExperience.self)),
        ("onboarding.goal.*", values(FinancialGoal.self)),
        ("onboarding.horizon.*", values(InvestmentHorizon.self)),
        ("onboarding.income.*", values(IncomeStability.self)),
        ("onboarding.emergencyFund.*", values(EmergencyFundStatus.self)),
        ("onboarding.debt.*", values(DebtStatus.self)),
        ("onboarding.risk.*", values(RiskAttitude.self)),
        ("safety.*.title", values(SafetyNote.self)),
        ("safety.*.body", values(SafetyNote.self)),
        ("password.issue.*", values(PasswordIssue.self)),
        ("lock.reason.*", values(LockReason.self)),
        ("auth.error.biometric.*", BiometricAvailability.allCases.map(\.localizationSuffix)),
        ("dashboard.range.*", values(DashboardRange.self)),
        ("overview.returnBasis.*", values(ReturnBasis.self)),
        ("range.*", values(ChartRange.self)),
        ("instrument.kind.*", values(InstrumentKind.self)),
        ("market.sort.*", values(MarketExplorerViewModel.SortOrder.self)),
        ("etf.replication.*", values(ReplicationMethod.self)),
        ("etf.distribution.*", values(DistributionPolicy.self)),
        ("transaction.type.*", values(TransactionType.self)),
        ("scenario.kind.*", values(ScenarioRange.Kind.self)),
        ("forecast.model.*", values(ForecastModelID.self)),
        ("risk.category.*", values(RiskCategory.self)),
        ("risk.level.*", values(RiskLevel.self)),
        ("planner.goal.term.*", values(PlannerGoal.Term.self)),
        ("planner.field.*", values(PlannerViewModel.Field.self)),
        ("simulator.mode.*", values(SimulatorMode.self)),
        ("strategy.rebalancing.*", values(StrategyBacktest.Rebalancing.self)),
        ("learn.stage.*", LearnViewModel.stages.map(String.init)),
        ("learn.status.*", values(LessonProgress.Status.self)),
        ("learn.calc.*.title", values(LessonCalculator.self)),
        ("news.category.*", values(NewsCategory.self)),
        ("news.type.*", values(StatementType.self)),
        ("news.uncertainty.*", values(UncertaintyLevel.self)),
        ("calendar.kind.*", values(EconomicEventKind.self)),
        ("calendar.status.*", values(EventStatus.self)),
        ("brokers.presence.*", values(BrokerEntry.CzechPresence.self)),
        ("brokers.licence.*", values(BrokerEntry.Licence.self)),
        ("notifications.kind.*", values(NotificationKind.self)),
        ("ai.flag.*", values(AIOutputFlag.self)),
        ("ai.provider.*", values(AIProviderKind.self)),
        ("link.warning.*", values(LinkWarning.self)),
    ]

    func testEveryRunTimeKeyHasAllTranslations() async throws {
        let catalog = try loadCatalog()
        var missing: [String] = []
        for family in Self.families {
            XCTAssertFalse(family.values.isEmpty, "\(family.template) has no values")
            for value in family.values {
                let key = family.template.replacingOccurrences(of: "*", with: value)
                for language in Self.languages where (catalog[key]?[language] ?? "").isEmpty {
                    missing.append("\(key) [\(language)]")
                }
            }
        }
        XCTAssertEqual(missing, [], "run-time localisation keys without a translation")
    }
}
