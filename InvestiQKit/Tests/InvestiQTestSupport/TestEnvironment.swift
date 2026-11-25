import Foundation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

/// Shared fixture for integration tests: temp directory, in-memory keychain, fake Touch ID, manual clock.
public final class TestContext {
    public let directory: TemporaryDirectory
    public let secureStore = InMemorySecureStore()
    public let biometrics = FakeBiometricKeyStore()
    public let clock = ManualTimeProvider(fixedNow)
    public var paths: ProfilePaths { ProfilePaths(baseDirectory: directory.url) }

    public init() throws { directory = try TemporaryDirectory() }
}
