import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQContent
import InvestiQServices

/// Course (spec §20): a step-by-step path from beginner to understanding the main instruments, with
/// quizzes and calculators. Finishing the course is not presented as readiness for real investing.
@MainActor
@Observable
public final class LearnViewModel {
    public static let stages = [1, 2, 3, 4]

    public private(set) var lessons: [Lesson] = []
    public private(set) var progress: [String: LessonProgress] = [:]
    public var selectedLessonID: String?
    public private(set) var error: Message?

    // Quiz state for the selected lesson.
    public var answers: [Int?] = []
    public private(set) var submittedScore: Int?

    // Calculator inputs (user-chosen; illustrations only).
    public var compoundInitial: Double = 10_000
    public var compoundMonthly: Double = 500
    public var compoundRate: Double = 0.05
    public var compoundYears: Int = 20
    public var inflationAmount: Double = 100_000
    public var inflationRate: Double = 0.03
    public var inflationYears: Int = 20
    public var feeAmount: Double = 100_000
    public var feeGross: Double = 0.05
    public var feeRate: Double = 0.01
    public var feeYears: Int = 30
    public var currencyAssetReturn: Double = 0.10
    public var currencyChange: Double = -0.10
    public var diversificationVolatility: Double = 0.30
    public var diversificationCorrelation: Double = 0.30

    private let app: AppModel
    private let language: String

    /// `languageCode` is the UI language ("ru", "en", "cs"); others fall back to English.
    public init(app: AppModel, languageCode: String?) {
        self.app = app
        language = LessonCatalog.language(for: languageCode)
    }

    public func load() async {
        do {
            lessons = try LessonCatalog.load(language: language)
            if let services = app.services { progress = try await services.learning.progress() }
            error = nil
        } catch {
            self.error = Message("learn.error.loadFailed")
        }
    }

    public func lessons(in stage: Int) -> [Lesson] { lessons.filter { $0.stage == stage } }
    public var selectedLesson: Lesson? { lessons.first { $0.id == selectedLessonID } }
    public func status(of lesson: Lesson) -> LessonProgress.Status { progress[lesson.id]?.status ?? .notStarted }
    public var completedCount: Int { lessons.filter { status(of: $0) == .completed }.count }
    public var isCourseComplete: Bool { !lessons.isEmpty && completedCount == lessons.count }

    /// The first lesson that is not completed (the suggested next step on the path).
    public var nextLesson: Lesson? { lessons.first { status(of: $0) != .completed } }

    public func open(_ lesson: Lesson) async {
        selectedLessonID = lesson.id
        answers = Array(repeating: nil, count: lesson.quiz.count)
        submittedScore = nil
        guard let services = app.services else { return }
        do {
            try await services.learning.markStarted(lesson.id)
            progress = try await services.learning.progress()
        } catch {
            self.error = Message("learn.error.saveFailed")
        }
    }

    public var canSubmit: Bool { !answers.isEmpty && answers.allSatisfy { $0 != nil } }

    public func submitQuiz() async {
        guard let lesson = selectedLesson, canSubmit else { return }
        let score = zip(answers, lesson.quiz).filter { $0.0 == $0.1.correctIndex }.count
        submittedScore = score
        guard let services = app.services else { return }
        do {
            try await services.learning.recordQuiz(lesson.id, score: score, total: lesson.quiz.count)
            progress = try await services.learning.progress()
        } catch {
            self.error = Message("learn.error.saveFailed")
        }
    }

    public func retryQuiz() {
        answers = Array(repeating: nil, count: selectedLesson?.quiz.count ?? 0)
        submittedScore = nil
    }

    // MARK: Calculators

    public var compoundPoints: [SavingsPoint] {
        FinancialPlanner.savingsScenario(initial: Decimal(finite: compoundInitial) ?? 0, monthly: Decimal(finite: compoundMonthly) ?? 0,
                                         annualReturn: Decimal(finite: compoundRate) ?? 0, inflation: 0, years: compoundYears)
    }
    public var inflationPoints: [LearningCalculators.YearValue] {
        LearningCalculators.inflation(amount: inflationAmount, rate: inflationRate, years: inflationYears)
    }
    public var feePoints: [LearningCalculators.YearValue] {
        LearningCalculators.feeDrag(amount: feeAmount, grossReturn: feeGross, fee: feeRate, years: feeYears)
    }
    public var currencyResult: Double {
        LearningCalculators.currencyAdjustedReturn(assetReturn: currencyAssetReturn, currencyChange: currencyChange)
    }
    public var diversificationPoints: [LearningCalculators.DiversificationPoint] {
        LearningCalculators.diversification(volatility: diversificationVolatility, correlation: diversificationCorrelation)
    }
}
