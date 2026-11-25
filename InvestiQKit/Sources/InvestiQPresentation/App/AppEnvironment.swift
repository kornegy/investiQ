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

    public init(paths: ProfilePaths, secureStore: any SecureStore, biometricStore: any BiometricKeyStore,
                passwordDerivation: any PasswordKeyDerivation, clock: any TimeProvider,
                httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.paths = paths
        self.secureStore = secureStore
        self.biometricStore = biometricStore
        self.passwordDerivation = passwordDerivation
        self.clock = clock
        self.httpClient = httpClient
    }
}

/// Services bound to one open session (real profile or demo). Rebuilt when provider settings change.
public struct SessionServices: Sendable {
    public let mode: SessionMode
    public let registry: ProviderRegistry
    public let instruments: InstrumentService
    public let marketData: MarketDataService
    public let exchangeRates: ExchangeRateService
    public let portfolios: PortfolioService
    /// `nil` in demo mode (no keys are ever used there).
    public let credentials: KeychainCredentials?

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
        return SessionServices(mode: session.mode, registry: registry,
                               instruments: InstrumentService(store: session.userStore, clock: clock),
                               marketData: marketData, exchangeRates: exchangeRates,
                               portfolios: PortfolioService(store: session.userStore, marketData: marketData, exchangeRates: exchangeRates, clock: clock),
                               credentials: credentials)
    }
}
