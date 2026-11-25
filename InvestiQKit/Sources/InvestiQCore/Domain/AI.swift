import Foundation

/// The only things AI is used for (spec §24). Each case carries exactly the data the task needs — never
/// amounts, holdings, profile answers, keys or passwords.
public enum AITask: Sendable, Hashable {
    case explainTerm(String)
    /// A computed metric: name, value as displayed, and the method description.
    case explainResult(metric: String, value: String, method: String)
    /// Untrusted external text (headline and short summary of a news item).
    case summarizeNews(headline: String, summary: String?, source: String)
    case answerEducationalQuestion(String)
    /// Risk category explanation; the level is included only when portfolio context is allowed.
    case explainRisk(category: String, level: String?)
    /// Instrument characteristics as label–value pairs already shown in the app.
    case compareInstruments([(name: String, facts: [(String, String)])])

    public static func == (lhs: AITask, rhs: AITask) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: String { String(describing: self) }
}

public enum AIOutputFlag: String, Sendable, Hashable, Codable, CaseIterable {
    /// The answer contains figures that were not in the data InvestiQ provided.
    case unverifiedFigures
    /// Links not present in the input were removed (AI must not invent sources).
    case removedLinks
    /// The input contained text that looked like instructions to the AI; it was treated as data.
    case injectionAttemptInInput
}

public struct AIAnswer: Sendable, Hashable {
    public var answer: String
    public var keyPoints: [String]
    public var caveats: [String]
    public var flags: Set<AIOutputFlag>
    public var provider: AIProviderKind
    /// True when the request left the Mac (external API).
    public var sentOffDevice: Bool

    public init(answer: String, keyPoints: [String], caveats: [String], flags: Set<AIOutputFlag>, provider: AIProviderKind, sentOffDevice: Bool) {
        self.answer = answer; self.keyPoints = keyPoints; self.caveats = caveats; self.flags = flags
        self.provider = provider; self.sentOffDevice = sentOffDevice
    }
}

public enum AIError: Error, Equatable, Sendable {
    case disabled
    case consentRequired
    case notAllowedInEducationalMode
    case providerUnavailable
    case missingConfiguration
    case blockedSensitiveData
    case invalidResponse
    case policyViolation
    case refused
    case transport
}
