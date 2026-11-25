import Foundation

/// User preferences persisted (encrypted) in the user database as one JSON document.
/// Every field decodes with a default so new preferences never require a migration.
public struct UserPreferences: Codable, Hashable, Sendable {
    public static let autoLockChoices = [1, 5, 15, 30]

    public var baseCurrency: CurrencyCode
    /// `nil` = follow the system language. Otherwise "ru", "en" or "cs".
    public var languageOverride: String?
    public var autoLockMinutes: Int
    public var onboardingCompleted: Bool
    public var notificationsEnabled: Bool
    /// Blue/orange instead of green/red for gains and losses.
    public var colorBlindSafePalette: Bool
    /// Contact e-mail for the SEC EDGAR User-Agent. `nil` disables SEC requests (privacy).
    public var secContactEmail: String?
    public var providerSettings: [ProviderSetting]
    public var aiSettings: AISettings
    /// Minimum minutes between automatic quote refreshes (no high-frequency polling).
    public var minimumRefreshMinutes: Int

    public init(baseCurrency: CurrencyCode = .czk, languageOverride: String? = nil, autoLockMinutes: Int = 5,
                onboardingCompleted: Bool = false, notificationsEnabled: Bool = false,
                colorBlindSafePalette: Bool = false, secContactEmail: String? = nil,
                providerSettings: [ProviderSetting] = [], aiSettings: AISettings = AISettings(),
                minimumRefreshMinutes: Int = 15) {
        self.baseCurrency = baseCurrency
        self.languageOverride = languageOverride
        self.autoLockMinutes = autoLockMinutes
        self.onboardingCompleted = onboardingCompleted
        self.notificationsEnabled = notificationsEnabled
        self.colorBlindSafePalette = colorBlindSafePalette
        self.secContactEmail = secContactEmail
        self.providerSettings = providerSettings
        self.aiSettings = aiSettings
        self.minimumRefreshMinutes = minimumRefreshMinutes
    }

    enum CodingKeys: String, CodingKey {
        case baseCurrency, languageOverride, autoLockMinutes, onboardingCompleted, notificationsEnabled,
             colorBlindSafePalette, secContactEmail, providerSettings, aiSettings, minimumRefreshMinutes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserPreferences()
        baseCurrency = try c.decodeIfPresent(CurrencyCode.self, forKey: .baseCurrency) ?? defaults.baseCurrency
        languageOverride = try c.decodeIfPresent(String.self, forKey: .languageOverride)
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? defaults.autoLockMinutes
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        colorBlindSafePalette = try c.decodeIfPresent(Bool.self, forKey: .colorBlindSafePalette) ?? false
        secContactEmail = try c.decodeIfPresent(String.self, forKey: .secContactEmail)
        providerSettings = try c.decodeIfPresent([ProviderSetting].self, forKey: .providerSettings) ?? []
        aiSettings = try c.decodeIfPresent(AISettings.self, forKey: .aiSettings) ?? AISettings()
        minimumRefreshMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumRefreshMinutes) ?? defaults.minimumRefreshMinutes
    }
}

public struct ProviderSetting: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var priority: Int
    public init(id: String, enabled: Bool, priority: Int) { self.id = id; self.enabled = enabled; self.priority = priority }
}

public enum AIProviderKind: String, Codable, Sendable, CaseIterable { case disabled, appleOnDevice, ollama, externalAPI }

/// AI is opt-in; external AI requires explicit consent (spec §24).
public struct AISettings: Codable, Hashable, Sendable {
    public var provider: AIProviderKind
    public var externalConsentGivenAt: Date?
    public var allowPortfolioContext: Bool
    public var ollamaEndpoint: String
    public var externalEndpoint: String?
    public var externalModel: String?

    public init(provider: AIProviderKind = .disabled, externalConsentGivenAt: Date? = nil, allowPortfolioContext: Bool = false,
                ollamaEndpoint: String = "http://127.0.0.1:11434", externalEndpoint: String? = nil, externalModel: String? = nil) {
        self.provider = provider
        self.externalConsentGivenAt = externalConsentGivenAt
        self.allowPortfolioContext = allowPortfolioContext
        self.ollamaEndpoint = ollamaEndpoint
        self.externalEndpoint = externalEndpoint
        self.externalModel = externalModel
    }
}
