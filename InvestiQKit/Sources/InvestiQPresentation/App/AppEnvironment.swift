import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices
import InvestiQData

/// Dependency container injected into view models (docs/ARCHITECTURE.md §2, no singletons).
/// The app target builds it with Apple adapters; tests build it with fakes.
public struct AppEnvironment: Sendable {
    public var paths: ProfilePaths
    public var secureStore: any SecureStore
    public var biometricStore: any BiometricKeyStore
    public var passwordDerivation: any PasswordKeyDerivation
    public var clock: any TimeProvider
    public var httpClient: any HTTPClient
    public var notificationDelivery: any NotificationDelivering
    /// Supplied by the app on systems with Apple Foundation Models (macOS 26+); nil elsewhere.
    public var onDeviceAIProvider: (@Sendable () -> (any AIProvider)?)?

    public init(paths: ProfilePaths, secureStore: any SecureStore, biometricStore: any BiometricKeyStore,
                passwordDerivation: any PasswordKeyDerivation, clock: any TimeProvider,
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                notificationDelivery: any NotificationDelivering = NoNotificationDelivery(),
                onDeviceAIProvider: (@Sendable () -> (any AIProvider)?)? = nil) {
        self.notificationDelivery = notificationDelivery
        self.onDeviceAIProvider = onDeviceAIProvider
        self.paths = paths
        self.secureStore = secureStore
        self.biometricStore = biometricStore
        self.passwordDerivation = passwordDerivation
        self.clock = clock
        self.httpClient = httpClient
    }
}

/// Delivers local notifications (UserNotifications in the app; a no-op in tests and on Linux).
@MainActor
public protocol NotificationDelivering: AnyObject, Sendable {
    func isAuthorized() async -> Bool
    func requestAuthorization() async -> Bool
    func deliver(_ notifications: [NotificationCandidate]) async
}

@MainActor
public final class NoNotificationDelivery: NotificationDelivering {
    public private(set) var delivered: [NotificationCandidate] = []
    public var authorized: Bool

    public nonisolated init(authorized: Bool = false) { self.authorized = authorized }
    public func isAuthorized() async -> Bool { authorized }
    public func requestAuthorization() async -> Bool { authorized }
    public func deliver(_ notifications: [NotificationCandidate]) async { delivered += notifications }
}

/// Services bound to one open session (real profile or demo). Rebuilt when provider settings change.
public struct SessionServices: Sendable {
    public let mode: SessionMode
    public let registry: ProviderRegistry
    public let instruments: InstrumentService
    public let marketData: MarketDataService
    public let exchangeRates: ExchangeRateService
    public let portfolios: PortfolioService
    public let forecasts: ForecastService
    public let risk: RiskService
    public let planner: PlannerService
    public let simulator: SimulatorService
    public let learning: LearningService
    public let news: NewsService
    public let calendar: CalendarService
    public let notifications: NotificationService
    public let ai: AIService
    public let profileData: ProfileDataService
    /// `nil` in demo mode (no keys are ever used there).
    public let credentials: KeychainCredentials?

    /// AI provider from settings. Demo sessions never use external AI (no keys exist there).
    static func makeAI(session: ProfileSession, preferences: UserPreferences, environment: AppEnvironment,
                       credentials: KeychainCredentials?) -> AIService {
        let settings = preferences.aiSettings
        let provider: (any AIProvider)?
        switch settings.provider {
        case .disabled: provider = nil
        case .appleOnDevice: provider = environment.onDeviceAIProvider?()
        case .ollama:
            provider = OllamaProvider(client: environment.httpClient, endpoint: settings.ollamaEndpoint, model: settings.externalModel)
        case .externalAPI:
            provider = credentials.map { AnthropicMessagesProvider(client: environment.httpClient, credentials: $0, model: settings.externalModel) }
        }
        let secretSource = credentials
        return AIService(provider: provider, settings: settings, knownSecrets: {
            ProviderCatalog.allProviderIDs.compactMap { secretSource?.apiKey(for: $0) }
                + [secretSource?.apiKey(for: AnthropicMessagesProvider.providerID)].compactMap { $0 }
        })
    }

    public static func make(session: ProfileSession, preferences: UserPreferences, environment: AppEnvironment) -> SessionServices {
        let clock = environment.clock
        let registry: ProviderRegistry
        let credentials: KeychainCredentials?
        switch session.mode {
        case .demo:
            registry = .demo(clock: clock)
            credentials = nil
        case .real:
            let keys = KeychainCredentials(store: environment.secureStore, profileID: session.profileID)
            let gateway = ProviderGateway(client: environment.httpClient, clock: clock, observer: CacheHealthObserver(store: session.cacheStore))
            registry = ProviderCatalog.makeRegistry(preferences: preferences, credentials: keys, gateway: gateway, clock: clock)
            credentials = keys
        }
        let marketData = MarketDataService(registry: registry, cache: session.cacheStore, clock: clock)
        let exchangeRates = ExchangeRateService(providers: registry.exchangeRates, cache: session.cacheStore, clock: clock)
        let instruments = InstrumentService(store: session.userStore, clock: clock)
        let portfolios = PortfolioService(store: session.userStore, marketData: marketData, exchangeRates: exchangeRates, clock: clock)
        let calendarService = CalendarService(registry: registry, instruments: instruments, clock: clock)
        return SessionServices(mode: session.mode, registry: registry, instruments: instruments,
                               marketData: marketData, exchangeRates: exchangeRates, portfolios: portfolios,
                               forecasts: ForecastService(store: session.userStore, marketData: marketData, clock: clock),
                               risk: RiskService(store: session.userStore, portfolios: portfolios, instruments: instruments,
                                                 marketData: marketData, clock: clock),
                               planner: PlannerService(store: session.userStore, clock: clock),
                               simulator: SimulatorService(store: session.userStore, portfolios: portfolios, instruments: instruments,
                                                           marketData: marketData, exchangeRates: exchangeRates, clock: clock),
                               learning: LearningService(store: session.userStore, clock: clock),
                               news: NewsService(registry: registry, cache: session.cacheStore, instruments: instruments, clock: clock),
                               calendar: calendarService,
                               notifications: NotificationService(userStore: session.userStore, cacheStore: session.cacheStore, registry: registry,
                                                                  portfolios: portfolios, instruments: instruments, marketData: marketData,
                                                                  calendar: calendarService, clock: clock),
                               ai: makeAI(session: session, preferences: preferences, environment: environment, credentials: credentials),
                               profileData: ProfileDataService(session: session),
                               credentials: credentials)
    }
}
