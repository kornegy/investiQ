import XCTest
@testable import InvestiQPlatformApple
import InvestiQSecurity

#if canImport(Security)
/// Runs on macOS only (CI). Uses a unique service prefix and cleans up after itself.
final class KeychainSecureStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = KeychainSecureStore(servicePrefix: "com.example.investiq.tests.\(UUID().uuidString)")
        let account = UUID().uuidString
        do {
            try store.set(Data("value-1".utf8), service: .apiKey, account: account)
        } catch SecureStoreError.interactionNotAllowed {
            throw XCTSkip("Keychain locked in this environment")
        }
        XCTAssertEqual(try store.data(service: .apiKey, account: account), Data("value-1".utf8))
        try store.set(Data("value-2".utf8), service: .apiKey, account: account)
        XCTAssertEqual(try store.data(service: .apiKey, account: account), Data("value-2".utf8))
        XCTAssertTrue(try store.accounts(service: .apiKey).contains(account))
        try store.remove(service: .apiKey, account: account)
        XCTAssertNil(try store.data(service: .apiKey, account: account))
        XCTAssertNoThrow(try store.remove(service: .apiKey, account: account))
    }
}
#else
final class KeychainSecureStoreTests: XCTestCase {
    func testPlatformAdaptersUnavailableOnLinux() { XCTAssertFalse(PlatformApple.isSupported) }
}
#endif
