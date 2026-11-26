import Foundation
import Observation
import InvestiQCore
import InvestiQServices

/// Runs one AI task and exposes the validated answer. Answers are shown as plain text with their flags;
/// they are never written to any record.
@MainActor
@Observable
public final class AIAssistantViewModel {
    public private(set) var answer: AIAnswer?
    public private(set) var error: Message?
    public private(set) var isWorking = false
    public var question = ""

    private let app: AppModel
    private let languageName: String

    /// `languageName` is the English name of the UI language ("Russian", "English", "Czech").
    public init(app: AppModel, languageName: String) {
        self.app = app
        self.languageName = languageName
    }

    public var isAvailable: Bool { app.services?.ai.isEnabled == true && app.services?.ai.hasProvider == true }
    public var sendsDataOffDevice: Bool { app.services?.ai.sendsDataOffDevice ?? false }

    public func run(_ task: AITask) async {
        guard let services = app.services else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            answer = try await services.ai.ask(task, languageName: languageName, educationalMode: app.educationalMode)
            error = nil
        } catch let failure as AIError {
            answer = nil
            error = Message("ai.error.\(String(describing: failure))")
        } catch {
            answer = nil
            self.error = Message("ai.error.transport")
        }
    }

    public func askQuestion() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run(.answerEducationalQuestion(trimmed))
    }

    public static func languageName(for code: String?) -> String {
        switch code {
        case "ru": return "Russian"
        case "cs": return "Czech"
        default: return "English"
        }
    }
}
