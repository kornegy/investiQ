import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices
import InvestiQPlatformApple
import InvestiQPresentation

/// Builds the production dependency graph with Apple adapters (no singletons; docs/ARCHITECTURE.md §3.6).
@MainActor
enum AppDependencies {
    static let uiTestingArgument = "--ui-testing"

    static func makeEnvironment() -> AppEnvironment {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uiTestingArgument) { return makeUITestingEnvironment() }
        #endif
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.InvestiQ"
        return AppEnvironment(paths: applicationSupportPaths(),
                              secureStore: KeychainSecureStore(servicePrefix: bundleID),
                              biometricStore: KeychainBiometricKeyStore(servicePrefix: bundleID),
                              passwordDerivation: Argon2idKeyDerivation(),
                              clock: SystemTimeProvider(),
                              notificationDelivery: UserNotificationDelivery(),
                              onDeviceAIProvider: { OnDeviceAI.provider() })
    }

    private static func applicationSupportPaths() -> ProfilePaths {
        if let paths = try? ProfilePaths.applicationSupport() { return paths }
        // Deterministic fallback inside the sandbox container (never a temporary directory).
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/InvestiQ", isDirectory: true)
        return ProfilePaths(baseDirectory: base)
    }

    #if DEBUG
    /// UI tests run against a throwaway directory and an in-memory keychain so they never touch the
    /// user's real data or Keychain. Only compiled into Debug builds.
    private static func makeUITestingEnvironment() -> AppEnvironment {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("InvestiQ-UITests-\(UUID().uuidString)")
        return AppEnvironment(paths: ProfilePaths(baseDirectory: base), secureStore: InMemorySecureStore(),
                              biometricStore: UnavailableBiometricKeyStore(),
                              passwordDerivation: Argon2idKeyDerivation.testing, clock: SystemTimeProvider())
    }
    #endif
}
