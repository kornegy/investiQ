import Foundation
import InvestiQCore

public enum LearningRecords {
    public static func all(in db: SQLiteDatabase) throws -> [LessonProgress] {
        try db.query("SELECT * FROM learning_progress").map { row in
            LessonProgress(lessonID: try row.string("lesson_id"), status: try row.enumValue("status"),
                           quizBestScore: row.optionalInt("quiz_best_score"), quizAttempts: try row.int("quiz_attempts"),
                           updatedAt: try row.instant("updated_at"))
        }
    }

    public static func save(_ progress: LessonProgress, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO learning_progress (lesson_id, status, quiz_best_score, quiz_attempts, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(lesson_id) DO UPDATE SET status = excluded.status, quiz_best_score = excluded.quiz_best_score,
                quiz_attempts = excluded.quiz_attempts, updated_at = excluded.updated_at
            """, [.text(progress.lessonID), .of(progress.status), .of(progress.quizBestScore), .integer(Int64(progress.quizAttempts)),
                  .of(progress.updatedAt)])
    }
}
