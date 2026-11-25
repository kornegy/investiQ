import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

/// Dependency container injected into view models (docs/ARCHITECTURE.md §2, no singletons).
/// The app target builds it with Apple adapters; tests build it with fakes.
public struct AppEnvironment: Sendable {
    public var paths: ProfilePaths
    public var secureStore: any SecureStore
    public var biometricStore: any BiometricKeyStore
    public var passwordDerivation: any PasswordKeyDerivation
    public var clock: any TimeProvider
    public var services: ServiceFactory

    public init(paths: ProfilePaths, secureStore: any SecureStore, biometricStore: any BiometricKeyStore,
                passwordDerivation: any PasswordKeyDerivation, clock: any TimeProvider,
                services: ServiceFactory = ServiceFactory()) {
        self.paths = paths
        self.secureStore = secureStore
        self.biometricStore = biometricStore
        self.passwordDerivation = passwordDerivation
        self.clock = clock
        self.services = services
    }
}

/// Creates per-session services. Extended in later phases (market data, portfolio, news, …).
public struct ServiceFactory: Sendable {
    public init() {}
}
