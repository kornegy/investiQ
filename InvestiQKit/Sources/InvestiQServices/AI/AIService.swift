import Foundation
import InvestiQCore
import InvestiQData
import InvestiQSecurity

/// Optional AI (spec §24, ADR-010). Off by default; the app works fully without it. External providers need
/// explicit consent and are unavailable in educational mode. AI output is advisory text only: it is never
/// stored in financial records and AI has no tools.
public actor AIService {
    private let provider: (any AIProvider)?
    private let settings: AISettings
    private let knownSecrets: @Sendable () -> [String]

    public init(provider: (any AIProvider)?, settings: AISettings, knownSecrets: @escaping @Sendable () -> [String]) {
        self.provider = provider
        self.settings = settings
        self.knownSecrets = knownSecrets
    }

    public nonisolated var providerKind: AIProviderKind { settings.provider }
    public nonisolated var hasProvider: Bool { provider != nil }
    public nonisolated var sendsDataOffDevice: Bool { provider?.sendsDataOffDevice ?? false }

    public nonisolated var isEnabled: Bool { settings.provider != .disabled }

    /// Whether risk levels derived from the user's own portfolio may be included (on-device: yes; external:
    /// only with the explicit "share portfolio context" setting).
    public func mayIncludePortfolioContext() -> Bool {
        guard let provider else { return false }
        return !provider.sendsDataOffDevice || settings.allowPortfolioContext
    }

    /// `educationalMode` is passed by the caller so it always reflects the current profile.
    public func ask(_ task: AITask, languageName: String, educationalMode: Bool) async throws -> AIAnswer {
        guard settings.provider != .disabled else { throw AIError.disabled }
        guard let provider else { throw AIError.providerUnavailable }
        if provider.sendsDataOffDevice {
            guard !educationalMode else { throw AIError.notAllowedInEducationalMode }
            guard settings.externalConsentGivenAt != nil else { throw AIError.consentRequired }
        }
        var minimized = task
        if case .explainRisk(let category, _) = task, !mayIncludePortfolioContext() { minimized = .explainRisk(category: category, level: nil) }
        let system = AIPrompts.system(languageName: languageName)
        let (prompt, injection) = AIPrompts.prompt(for: minimized)
        guard !PromptGuard.containsSecret(system + prompt, knownSecrets: knownSecrets()) else { throw AIError.blockedSensitiveData }
        let raw = try await provider.complete(system: system, prompt: prompt, schema: AIAnswerSchema.jsonSchema)
        var result = try AIOutputValidator.validate(raw, input: prompt)
        if injection { result.flags.insert(.injectionAttemptInInput) }
        return AIAnswer(answer: result.answer, keyPoints: result.keyPoints, caveats: result.caveats, flags: result.flags,
                        provider: provider.kind, sentOffDevice: provider.sendsDataOffDevice)
    }
}
