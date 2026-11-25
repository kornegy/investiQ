import XCTest
@testable import InvestiQPresentation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQSecurity
import InvestiQTestSupport

@MainActor
final class AnalysisViewModelTests: XCTestCase {
    func demoApp() async throws -> AppModel {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        return app
    }

    func analysis(for demo: DemoInstrument, app: AppModel) async -> AssetAnalysisViewModel {
        let details = AssetDetailsViewModel(app: app, instrumentID: demo.instrument.id)
        await details.load()
        let analysis = AssetAnalysisViewModel(app: app)
        analysis.update(from: details)
        return analysis
    }

    func testStockAnalysisProducesNeutralStatusesAndScenarioRanges() async throws {
        let app = try await demoApp()
        let model = await analysis(for: DemoUniverse.all[0], app: app)
        let assessment = try XCTUnwrap(model.assessment)
        XCTAssertFalse(assessment.statuses.isEmpty)
        XCTAssertFalse(assessment.guidingQuestions.isEmpty)
        let scenarios = try XCTUnwrap(model.scenarios, "demo history covers more than three years")
        XCTAssertEqual(scenarios.map(\.kind), [.pessimistic, .base, .optimistic])
        XCTAssertLessThanOrEqual(scenarios[0].endValue, scenarios[1].endValue)
        XCTAssertLessThanOrEqual(scenarios[1].endValue, scenarios[2].endValue)
        XCTAssertEqual(model.sensitivity.count, 15)

        model.illustrationAmount = 1_000
        XCTAssertEqual(model.scenarios?[1].endValue ?? 0, scenarios[1].endValue / 10, accuracy: 1e-6)
    }

    func testBondAndETFAnalysis() async throws {
        let app = try await demoApp()
        let bond = await analysis(for: DemoUniverse.all[10], app: app)
        let bondAnalysis = try XCTUnwrap(bond.bondAnalysis)
        XCTAssertNotNil(bondAnalysis.yieldToMaturity)
        XCTAssertNotNil(bondAnalysis.risk?.modified)
        XCTAssertNil(bond.assessment, "stock rules are not applied to bonds")

        let etf = await analysis(for: DemoUniverse.all[7], app: app)
        XCTAssertNotNil(etf.etfAnalysis?.costDragExample)
    }

    func testValidationAndForecastRecording() async throws {
        let app = try await demoApp()
        let model = await analysis(for: DemoUniverse.all[3], app: app)
        await model.runValidation()
        XCTAssertEqual(Set(model.validations.map(\.model)), Set(ForecastModelID.allCases))
        XCTAssertTrue(model.validations.allSatisfy { $0.evaluations >= WalkForwardValidator.minimumEvaluations })
        let naive = try XCTUnwrap(model.validations.first { $0.model == .naive })
        XCTAssertEqual(naive.relativeMAE ?? 0, 1, accuracy: 1e-9, "the naive model is its own out-of-sample baseline")
        XCTAssertNotNil(naive.mase)
        XCTAssertFalse(naive.isUsefulSignal)

        model.forecastModel = .bootstrap
        await model.recordForecast()
        XCTAssertNil(model.forecastMessage)
        XCTAssertEqual(model.recordedForecast?.modelID, ForecastModelID.bootstrap.rawValue)

        let record = ForecastAccuracyViewModel(app: app)
        await record.load()
        XCTAssertEqual(record.items.count, 1)
        XCTAssertEqual(record.items.first?.instrumentName, DemoUniverse.all[3].instrument.name)
        XCTAssertEqual(record.pendingCount, 1)
    }

    func testRiskViewModelRunsStressTestsOnDemoPortfolio() async throws {
        let app = try await demoApp()
        let model = RiskViewModel(app: app)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.hasHoldings)
        XCTAssertEqual(model.sortedCategories.count, RiskCategory.allCases.count)
        if let firstUnknown = model.sortedCategories.firstIndex(where: { $0.level == .unknown }) {
            XCTAssertTrue(model.sortedCategories[firstUnknown...].allSatisfy { $0.level == .unknown }, "unknown levels are listed last")
        }
        let equity = try XCTUnwrap(model.stressResults[.equityMinus20])
        XCTAssertLessThan(equity.changeBase, 0)
        XCTAssertTrue(equity.assumptions.contains(Message("stress.hypothetical")), "stress tests are labelled hypothetical")
        let deeper = try XCTUnwrap(model.stressResults[.equityMinus40])
        XCTAssertLessThan(deeper.changeBase, equity.changeBase)
        XCTAssertNotNil(model.stressResults[.largestIssuerDefault])
    }
}

@MainActor
final class PlannerViewModelTests: XCTestCase {
    func testPlannerParsesSavesAndReloads() async throws {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        let model = PlannerViewModel(app: app, locale: Locale(identifier: "cs_CZ"))
        await model.load()
        model.texts[.monthlyIncome] = "50 000"
        model.texts[.essentialExpenses] = "25000"
        model.texts[.additionalExpenses] = "10000"
        model.texts[.debtPayments] = "0"
        model.texts[.emergencyFund] = "abc"
        model.recompute()
        XCTAssertEqual(model.invalidField, .emergencyFund)
        XCTAssertNil(model.analysis)
        model.texts[.emergencyFund] = "100000,5"
        model.recompute()
        XCTAssertNil(model.invalidField)
        XCTAssertEqual(model.analysis?.freeCashFlow, 15_000)
        await model.save()
        XCTAssertTrue(model.saved)
        let added = await model.addGoal(name: "  Bike ", term: .short, amountText: "12000", targetDate: .d("2027-11-30"))
        XCTAssertTrue(added)
        XCTAssertEqual(model.goals.first?.name, "Bike")

        let reloaded = PlannerViewModel(app: app, locale: Locale(identifier: "cs_CZ"))
        await reloaded.load()
        XCTAssertEqual(reloaded.budget?.emergencyFund, Decimal(string: "100000.5"))
        XCTAssertEqual(reloaded.goals.count, 1)
        XCTAssertFalse(reloaded.savings.isEmpty)
    }
}
