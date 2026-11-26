import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQSecurity
import InvestiQPersistence
import InvestiQTestSupport

final class ProfileServiceTests: XCTestCase {
    var dir: TemporaryDirectory!
    var store: InMemorySecureStore!
    var biometrics: FakeBiometricKeyStore!
    var clock: ManualTimeProvider!
    var service: ProfileService!
    let password = "Dlouhé heslo 2026!"

    override func setUp() async throws {
        dir = try TemporaryDirectory()
        store = InMemorySecureStore()
        biometrics = FakeBiometricKeyStore()
        clock = ManualTimeProvider(fixedNow)
        service = ProfileService(paths: ProfilePaths(baseDirectory: dir.url), secureStore: store, biometricStore: biometrics,
                                 derivation: Argon2idKeyDerivation.testing, clock: clock)
    }

    func testCreateAndUnlock() async throws {
        let created = try await service.createProfile(displayName: "  Osobní  ", password: password, confirmation: password)
        XCTAssertEqual(created.summary.displayName, "Osobní")
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.id), [created.summary.id])
        let unlocked = try await service.unlock(id: created.summary.id, password: password)
        XCTAssertEqual(CryptoBox.keyData(unlocked.dataKey), CryptoBox.keyData(created.dataKey))
        // No password or hash is stored anywhere in the secure store or on disk.
        let envelope = try XCTUnwrap(try store.data(service: .keyEnvelope, account: created.summary.id.string))
        XCTAssertNil(envelope.range(of: Data(password.utf8)))
    }

    func testRejectsWeakPasswordAndInvalidName() async {
        do {
            _ = try await service.createProfile(displayName: "A", password: "short", confirmation: "short")
            XCTFail("expected weak password")
        } catch {
            XCTAssertEqual(error as? ProfileError, .weakPassword([.tooShort]))
        }
        do {
            _ = try await service.createProfile(displayName: "   ", password: password, confirmation: password)
            XCTFail("expected invalid name")
        } catch {
            XCTAssertEqual(error as? ProfileError, .invalidDisplayName)
        }
    }

    func testWrongPasswordIsThrottled() async throws {
        let id = try await service.createProfile(displayName: "P", password: password, confirmation: password).summary.id
        for expected in [4, 3, 2, 1, 0] {
            do {
                _ = try await service.unlock(id: id, password: "wrong password!")
                XCTFail("expected failure")
            } catch ProfileError.wrongPassword(let remaining) {
                XCTAssertEqual(remaining, expected)
            } catch ProfileError.lockedOut {
                XCTAssertEqual(expected, 0)
            }
        }
        // Even the correct password is refused while locked out.
        do {
            _ = try await service.unlock(id: id, password: password)
            XCTFail("expected lockout")
        } catch {
            guard case ProfileError.lockedOut = error else { return XCTFail("\(error)") }
        }
        clock.advance(by: 31)
        _ = try await service.unlock(id: id, password: password)
        let decision = try await service.throttleDecision(for: id)
        XCTAssertEqual(decision, .allowed(remainingFreeAttempts: 5))
    }

    func testChangePasswordKeepsDataKey() async throws {
        let created = try await service.createProfile(displayName: "P", password: password, confirmation: password)
        let newPassword = "Úplně nové heslo 77"
        try await service.changePassword(id: created.summary.id, current: password, new: newPassword, confirmation: newPassword)
        let unlocked = try await service.unlock(id: created.summary.id, password: newPassword)
        XCTAssertEqual(CryptoBox.keyData(unlocked.dataKey), CryptoBox.keyData(created.dataKey))
        do {
            _ = try await service.unlock(id: created.summary.id, password: password)
            XCTFail("old password must stop working")
        } catch {}
    }

    func testBiometricUnlock() async throws {
        let created = try await service.createProfile(displayName: "P", password: password, confirmation: password)
        let id = created.summary.id
        do {
            _ = try await service.unlockWithBiometrics(id: id, reason: "test")
            XCTFail("not enabled yet")
        } catch {
            XCTAssertEqual(error as? ProfileError, .biometricNotEnabled)
        }
        try await service.setBiometricUnlock(enabled: true, profile: created)
        let unlocked = try await service.unlockWithBiometrics(id: id, reason: "test")
        XCTAssertEqual(CryptoBox.keyData(unlocked.dataKey), CryptoBox.keyData(created.dataKey))
        biometrics.shouldFail = true
        do {
            _ = try await service.unlockWithBiometrics(id: id, reason: "test")
            XCTFail("cancelled biometrics must fail")
        } catch {
            XCTAssertEqual(error as? ProfileError, .biometricFailed)
        }
        biometrics.currentAvailability = .entitlementMissing
        do {
            try await service.setBiometricUnlock(enabled: true, profile: created)
            XCTFail("must not enable without entitlement")
        } catch {
            XCTAssertEqual(error as? ProfileError, .biometricUnavailable(.entitlementMissing))
        }
    }

    func testDeleteProfileShredsKeysAndFiles() async throws {
        let created = try await service.createProfile(displayName: "P", password: password, confirmation: password)
        let id = created.summary.id
        try await service.setBiometricUnlock(enabled: true, profile: created)
        try store.set(Data("k".utf8), service: .apiKey, account: "\(id.string)/finnhub")
        let session = try ProfileSession.open(created, paths: ProfilePaths(baseDirectory: dir.url), clock: clock)
        try await session.userStore.write { try $0.run("INSERT INTO watchlists (id, name, created_at) VALUES ('w','W','x')") }
        await session.close()
        let paths = ProfilePaths(baseDirectory: dir.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.userDatabase(for: id).path))

        do {
            try await service.deleteProfile(id: id, password: "wrong password!")
            XCTFail("deletion requires the password")
        } catch {}
        try await service.deleteProfile(id: id, password: password)
        XCTAssertNil(try store.data(service: .keyEnvelope, account: id.string))
        XCTAssertNil(try store.data(service: .apiKey, account: "\(id.string)/finnhub"))
        XCTAssertFalse(biometrics.hasKey(account: id.string))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory(for: id).path))
        let remaining = try await service.profiles()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSessionPersistsUserDataEncrypted() async throws {
        let created = try await service.createProfile(displayName: "P", password: password, confirmation: password)
        let paths = ProfilePaths(baseDirectory: dir.url)
        let session = try ProfileSession.open(created, paths: paths, clock: clock)
        let data = ProfileDataService(session: session)
        var prefs = try await data.preferences()
        XCTAssertFalse(prefs.onboardingCompleted)
        prefs.onboardingCompleted = true
        prefs.baseCurrency = .eur
        try await data.savePreferences(prefs)
        await session.close()

        let reopened = try ProfileSession.open(try await service.unlock(id: created.summary.id, password: password), paths: paths, clock: clock)
        let loaded = try await ProfileDataService(session: reopened).preferences()
        XCTAssertTrue(loaded.onboardingCompleted)
        XCTAssertEqual(loaded.baseCurrency, .eur)
        let raw = try Data(contentsOf: paths.userDatabase(for: created.summary.id))
        XCTAssertNil(raw.range(of: Data("onboardingCompleted".utf8)))
    }
}
