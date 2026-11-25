import Foundation
import Observation
import InvestiQCore
import InvestiQData
import InvestiQServices

/// Settings → AI (spec §24). AI is off by default. External AI requires explicit consent each time it is
/// switched on, is blocked in educational mode, and never receives portfolio context unless allowed.
@MainActor
@Observable
public final class AISettingsViewModel {
    public private(set) var settings: AISettings
    public private(set) var hasExternalKey = false
    public private(set) var message: Message?
    public var ollamaEndpoint: String
    public var modelName: String

    private let app: AppModel

    public init(app: AppModel) {
        self.app = app
        settings = app.preferences.aiSettings
        ollamaEndpoint = app.preferences.aiSettings.ollamaEndpoint
        modelName = app.preferences.aiSettings.externalModel ?? ""
    }

    public var isEducationalMode: Bool { app.educationalMode }
    public var isDemo: Bool { app.isDemo }
    public var onDeviceAvailable: Bool { app.environment.onDeviceAIProvider?() != nil }
    public var defaultExternalModel: String { AnthropicMessagesProvider.defaultModel }

    public func load() {
        settings = app.preferences.aiSettings
        hasExternalKey = app.services?.credentials?.apiKey(for: AnthropicMessagesProvider.providerID) != nil
    }

    /// Providers that can be chosen now. External AI is not offered to minors or in demo mode.
    public var availableProviders: [AIProviderKind] {
        AIProviderKind.allCases.filter { kind in
            switch kind {
            case .disabled, .ollama: return true
            case .appleOnDevice: return onDeviceAvailable
            case .externalAPI: return !isEducationalMode && !isDemo
            }
        }
    }

    /// Choosing the external provider requires `consented == true` (the consent dialog's confirmation).
    public func select(_ kind: AIProviderKind, consented: Bool = false) async {
        guard availableProviders.contains(kind) else { message = Message("ai.error.notAvailable"); return }
        if kind == .externalAPI && !consented { message = Message("ai.error.consentRequired"); return }
        await save { settings in
            settings.provider = kind
            settings.externalConsentGivenAt = kind == .externalAPI ? self.app.environment.clock.now() : nil
            if kind != .externalAPI { settings.allowPortfolioContext = false }
        }
    }

    public func setPortfolioContext(_ allowed: Bool) async {
        await save { $0.allowPortfolioContext = allowed }
    }

    public func saveConnection() async {
        let endpoint = ollamaEndpoint.trimmingCharacters(in: .whitespaces)
        if settings.provider == .ollama {
            guard let url = URL(string: endpoint), HTTPRequest(url: url).usesAllowedTransport,
                  ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host?.lowercased() ?? "") else {
                message = Message("ai.error.localOnly")
                return
            }
        }
        let model = modelName.trimmingCharacters(in: .whitespaces)
        await save { settings in
            settings.ollamaEndpoint = endpoint
            settings.externalModel = model.isEmpty ? nil : model
        }
    }

    /// Stores the external API key in the Keychain (never in preferences, logs or backups).
    public func saveExternalKey(_ key: String) async {
        guard let credentials = app.services?.credentials else { return }
        do {
            try credentials.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: AnthropicMessagesProvider.providerID)
            app.reloadServices()
            load()
            message = Message("ai.keySaved")
        } catch {
            message = Message("settings.error.saveFailed")
        }
    }

    private func save(_ change: @escaping (inout AISettings) -> Void) async {
        do {
            try await app.updatePreferences { change(&$0.aiSettings) }
            settings = app.preferences.aiSettings
            message = nil
        } catch {
            message = Message("settings.error.saveFailed")
        }
    }
}
