import Foundation
import InvestiQCore
import InvestiQPersistence

public enum LearningError: Error, Equatable, Sendable { case invalidScore }

/// Stores course progress. Completing the course is never treated as proof of readiness to invest.
public actor LearningService {
    /// A lesson counts as completed when at least this share of its quiz is answered correctly.
    public static let passingShare = 2.0 / 3.0

    private let store: DatabaseStore
    private let clock: any TimeProvider

    public init(store: DatabaseStore, clock: any TimeProvider) {
        self.store = store
        self.clock = clock
    }

    public func progress() async throws -> [String: LessonProgress] {
        let rows = try await store.read { try LearningRecords.all(in: $0) }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.lessonID, $0) })
    }

    public func markStarted(_ lessonID: String) async throws {
        let existing = try await progress()[lessonID]
        guard existing == nil || existing?.status == .notStarted else { return }
        let row = LessonProgress(lessonID: lessonID, status: .inProgress, quizBestScore: nil, quizAttempts: 0, updatedAt: clock.now())
        try await store.write { try LearningRecords.save(row, in: $0) }
    }

    /// Records a quiz attempt and returns the updated progress.
    @discardableResult
    public func recordQuiz(_ lessonID: String, score: Int, total: Int) async throws -> LessonProgress {
        guard total > 0, (0...total).contains(score) else { throw LearningError.invalidScore }
        let existing = try await progress()[lessonID]
        let best = max(existing?.quizBestScore ?? 0, score)
        let passed = Double(best) >= Self.passingShare * Double(total) - 1e-9
        let row = LessonProgress(lessonID: lessonID, status: passed ? .completed : .inProgress, quizBestScore: best,
                                 quizAttempts: (existing?.quizAttempts ?? 0) + 1, updatedAt: clock.now())
        try await store.write { try LearningRecords.save(row, in: $0) }
        return row
    }
}
