import Foundation

/// Interactive calculator attached to a lesson.
public enum LessonCalculator: String, Codable, Sendable, CaseIterable {
    case compoundInterest, inflation, diversification, feeDrag, currency
}

public struct LessonSection: Codable, Sendable, Hashable {
    public var heading: String
    public var body: String
}

public struct QuizQuestion: Codable, Sendable, Hashable {
    public var question: String
    public var options: [String]
    public var correctIndex: Int
    public var explanation: String
}

/// One lesson of the course (content in docs: Content/lessons, built by scripts/build_lessons.py).
public struct Lesson: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var order: Int
    /// 1 foundations · 2 instruments · 3 risk and costs · 4 practice and protection.
    public var stage: Int
    public var minutes: Int
    public var calculator: LessonCalculator?
    public var title: String
    public var summary: String
    public var sections: [LessonSection]
    public var analogy: String
    public var keyPoints: [String]
    public var quiz: [QuizQuestion]
}

public enum LessonCatalogError: Error, Equatable, Sendable {
    case missingResource(String)
    case invalidContent(String)
}

/// Loads the bundled course for a language (falls back to English for unsupported languages).
public enum LessonCatalog {
    public static let supportedLanguages = ["ru", "en", "cs"]
    public static let fallbackLanguage = "en"

    private struct File: Decodable {
        var version: Int
        var language: String
        var lessons: [Lesson]
    }

    public static func language(for preferred: String?) -> String {
        guard let preferred, supportedLanguages.contains(preferred) else { return fallbackLanguage }
        return preferred
    }

    public static func load(language: String) throws -> [Lesson] {
        let code = Self.language(for: language)
        guard let url = Bundle.module.url(forResource: code, withExtension: "json", subdirectory: "Resources/lessons") else {
            throw LessonCatalogError.missingResource(code)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        for lesson in file.lessons {
            for question in lesson.quiz where !question.options.indices.contains(question.correctIndex) {
                throw LessonCatalogError.invalidContent(lesson.id)
            }
        }
        return file.lessons.sorted { $0.order < $1.order }
    }
}
