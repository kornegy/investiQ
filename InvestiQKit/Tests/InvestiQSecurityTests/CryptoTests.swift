import XCTest
@testable import InvestiQSecurity
import InvestiQCore
import InvestiQTestSupport

final class CryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let key = CryptoBox.randomKey()
        let aad = Data("header".utf8)
        let sealed = try CryptoBox.seal(Data("secret ledger".utf8), key: key, associatedData: aad)
        XCTAssertEqual(try CryptoBox.open(sealed, key: key, associatedData: aad), Data("secret ledger".utf8))
        // Fresh random nonce each time → different ciphertexts.
        XCTAssertNotEqual(sealed, try CryptoBox.seal(Data("secret ledger".utf8), key: key, associatedData: aad))
    }

    func testTamperWrongKeyAndWrongAADAreDetected() throws {
        let key = CryptoBox.randomKey()
        let aad = Data("header".utf8)
        var sealed = try CryptoBox.seal(Data(repeating: 7, count: 64), key: key, associatedData: aad)
        XCTAssertThrowsError(try CryptoBox.open(sealed, key: CryptoBox.randomKey(), associatedData: aad)) {
            XCTAssertEqual($0 as? CryptoError, .authenticationFailed)
        }
        XCTAssertThrowsError(try CryptoBox.open(sealed, key: key, associatedData: Data("other".utf8))) {
            XCTAssertEqual($0 as? CryptoError, .authenticationFailed)
        }
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try CryptoBox.open(sealed, key: key, associatedData: aad)) {
            XCTAssertEqual($0 as? CryptoError, .authenticationFailed)
        }
        XCTAssertThrowsError(try CryptoBox.open(Data([1, 2, 3]), key: key, associatedData: aad)) {
            XCTAssertEqual($0 as? CryptoError, .malformedCiphertext)
        }
    }

    func testDerivedKeysDifferPerPurpose() {
        let master = CryptoBox.randomKey()
        let a = CryptoBox.keyData(CryptoBox.deriveKey(from: master, purpose: KeyPurpose.userDatabase))
        let b = CryptoBox.keyData(CryptoBox.deriveKey(from: master, purpose: KeyPurpose.cacheDatabase))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, CryptoBox.keyData(CryptoBox.deriveKey(from: master, purpose: KeyPurpose.userDatabase)))
        XCTAssertEqual(a.count, 32)
    }

    func testArgon2idIsDeterministicPerSaltAndSensitiveToInputs() throws {
        let kdf = Argon2idKeyDerivation.testing
        let params = kdf.makeParameters()
        XCTAssertEqual(params.algorithm, "argon2id13")
        XCTAssertEqual(params.salt.count, 16)
        let k1 = CryptoBox.keyData(try kdf.deriveKey(password: "correct horse battery", parameters: params))
        let k2 = CryptoBox.keyData(try kdf.deriveKey(password: "correct horse battery", parameters: params))
        let k3 = CryptoBox.keyData(try kdf.deriveKey(password: "correct horse batterz", parameters: params))
        let k4 = CryptoBox.keyData(try kdf.deriveKey(password: "correct horse battery", parameters: kdf.makeParameters()))
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
        XCTAssertNotEqual(k1, k4)
    }

    func testArgon2idKnownVector() throws {
        // libsodium crypto_pwhash(ARGON2ID13, outlen 32, "pw", salt 0x01×16, ops 3, mem 64 MiB) — computed
        // with libsodium 1.0.22 during environment verification (docs/SECURITY.md §2).
        let params = KDFParameters(algorithm: "argon2id13", opsLimit: 3, memLimitBytes: 64 * 1024 * 1024, salt: Data(repeating: 1, count: 16))
        let key = try Argon2idKeyDerivation().deriveKey(password: "pw", parameters: params)
        XCTAssertEqual(CryptoBox.keyData(key).map { String(format: "%02x", $0) }.joined(),
                       "6cc8330b81cc4258e0806d00d18523028996d710cd2bebfc703ab616a18ea0f6")
    }

    func testUnicodeNormalizationOfPasswords() throws {
        let kdf = Argon2idKeyDerivation.testing
        let params = kdf.makeParameters()
        let composed = "heslo-\u{00E9}" // é as one scalar
        let decomposed = "heslo-e\u{0301}" // e + combining acute
        XCTAssertEqual(CryptoBox.keyData(try kdf.deriveKey(password: composed, parameters: params)),
                       CryptoBox.keyData(try kdf.deriveKey(password: decomposed, parameters: params)))
    }

    func testRejectsUnknownKDFAlgorithm() {
        let params = KDFParameters(algorithm: "pbkdf2", opsLimit: 1, memLimitBytes: 8 * 1024 * 1024, salt: Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try Argon2idKeyDerivation.testing.deriveKey(password: "x", parameters: params))
    }

    func testKeyEnvelopeUnwrapAndWrongPassword() throws {
        let dek = CryptoBox.randomKey()
        let profile = ProfileID()
        let envelope = try KeyEnvelope.create(dataKey: dek, password: "Správné heslo 42", profileID: profile,
                                              derivation: Argon2idKeyDerivation.testing, now: fixedNow)
        let unwrapped = try envelope.unwrap(password: "Správné heslo 42", derivation: Argon2idKeyDerivation.testing)
        XCTAssertEqual(CryptoBox.keyData(unwrapped), CryptoBox.keyData(dek))
        XCTAssertThrowsError(try envelope.unwrap(password: "wrong password", derivation: Argon2idKeyDerivation.testing)) {
            XCTAssertEqual($0 as? KeyEnvelopeError, .wrongPassword)
        }
        // Envelope bound to its profile: changing the profile ID breaks authentication.
        var moved = envelope
        moved.profileID = ProfileID().string
        XCTAssertThrowsError(try moved.unwrap(password: "Správné heslo 42", derivation: Argon2idKeyDerivation.testing))
        // Serialisation round trip.
        let decoded = try KeyEnvelope.decode(try envelope.encoded())
        XCTAssertEqual(decoded, envelope)
        XCTAssertThrowsError(try KeyEnvelope.decode(Data("{}".utf8)))
    }
}
