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

@MainActor
final class SimulatorViewModelTests: XCTestCase {
    func testCreateHistoricalSessionTradeAndAdvance() async throws {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        let model = SimulatorViewModel(app: app, locale: Locale(identifier: "en_US"))
        await model.load()
        model.newCapitalText = "50000"
        let created = await model.createSession(defaultName: "Historical")
        XCTAssertTrue(created)
        XCTAssertEqual(model.selected?.portfolio.name, "Historical")
        XCTAssertNotNil(model.report)
        model.orderInstrumentID = DemoUniverse.all[0].instrument.id
        model.orderQuantityText = "10"
        await model.updatePreview()
        XCTAssertNotNil(model.preview)
        await model.placeOrder()
        XCTAssertEqual(model.orderMessage, Message("simulator.order.done"))
        XCTAssertEqual(model.heldInstruments.map(\.id), [DemoUniverse.all[0].instrument.id])
        let before = try XCTUnwrap(model.selected?.session.simDate)
        await model.advance(days: 7)
        XCTAssertEqual(model.selected?.session.simDate, before.adding(days: 7))
        XCTAssertNotNil(model.differenceToBenchmark)

        let lab = StrategyLabViewModel(app: app, locale: Locale(identifier: "en_US"))
        await lab.load()
        lab.start = LocalDate.d("2018-01-02").startOfDay(in: .current)
        await lab.run()
        XCTAssertNil(lab.error)
        XCTAssertNotNil(lab.strategy)
        lab.rows[0].weightText = "70"
        await lab.run()
        XCTAssertEqual(lab.error, Message("strategy.error.weights"))
    }
}

@MainActor
final class LearnViewModelTests: XCTestCase {
    func testPathQuizAndProgress() async throws {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        let model = LearnViewModel(app: app, languageCode: "cs")
        await model.load()
        XCTAssertEqual(model.lessons.count, 21)
        XCTAssertEqual(LearnViewModel.stages.flatMap { model.lessons(in: $0) }.count, 21)
        let first = try XCTUnwrap(model.nextLesson)
        await model.open(first)
        XCTAssertEqual(model.status(of: first), .inProgress)
        XCTAssertFalse(model.canSubmit)
        // Wrong answers: still in progress.
        model.answers = first.quiz.map { ($0.correctIndex + 1) % $0.options.count }
        await model.submitQuiz()
        XCTAssertEqual(model.submittedScore, 0)
        XCTAssertEqual(model.status(of: first), .inProgress)
        model.retryQuiz()
        model.answers = first.quiz.map(\.correctIndex)
        await model.submitQuiz()
        XCTAssertEqual(model.submittedScore, first.quiz.count)
        XCTAssertEqual(model.status(of: first), .completed)
        XCTAssertEqual(model.progress[first.id]?.quizAttempts, 2)
        XCTAssertNotEqual(model.nextLesson?.id, first.id)
        XCTAssertFalse(model.isCourseComplete)
        XCTAssertEqual(model.compoundPoints.count, model.compoundYears)
    }
}

@MainActor
final class NewsViewModelTests: XCTestCase {
    func testDemoNewsFiltersEffectsAndCalendar() async throws {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        let news = NewsViewModel(app: app)
        await news.load()
        XCTAssertFalse(news.articles.isEmpty)
        XCTAssertTrue(news.articles.allSatisfy { !news.canOpen($0) }, "demo links are never opened")
        news.typeFilter = .rumour
        XCTAssertEqual(news.filtered.count, 1)
        news.typeFilter = nil
        news.categoryFilter = .inflation
        let inflation = try XCTUnwrap(news.filtered.first)
        XCTAssertEqual(news.possibleEffects(inflation).last, Message("news.effect.caveat"), "effects always end with the caveat")
        news.categoryFilter = nil
        news.onlyMyInstruments = true
        XCTAssertTrue(news.filtered.allSatisfy { !$0.relatedInstrumentIDs.isEmpty })

        let calendar = CalendarViewModel(app: app)
        await calendar.load()
        XCTAssertFalse(calendar.days.isEmpty)
        calendar.kindFilter = .centralBankDecision
        XCTAssertTrue(calendar.filtered.allSatisfy { $0.kind == .centralBankDecision })
        XCTAssertEqual(calendar.title(calendar.filtered[0]).key, "calendar.title.centralBankDecision")
    }
}
