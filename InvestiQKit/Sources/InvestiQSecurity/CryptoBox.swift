import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CryptoError: Error, Equatable, Sendable {
    /// Authentication tag mismatch: wrong key, wrong associated data or tampered ciphertext.
    case authenticationFailed
    case malformedCiphertext
    case keyDerivationFailed
    case randomGenerationFailed
}

/// Thin wrapper over AES-256-GCM and HKDF-SHA256. No custom cryptography (docs/SECURITY.md §2).
public enum CryptoBox {
    public static let keyByteCount = 32
    static let nonceByteCount = 12
    static let tagByteCount = 16

    /// Encrypts and returns `nonce ‖ ciphertext ‖ tag`.
    public static func seal(_ plaintext: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: associatedData)
        guard let combined = box.combined else { throw CryptoError.malformedCiphertext }
        return combined
    }

    public static func open(_ combined: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        guard combined.count >= nonceByteCount + tagByteCount else { throw CryptoError.malformedCiphertext }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw CryptoError.malformedCiphertext
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    /// Derives an independent sub-key for a purpose label (HKDF-SHA256).
    public static func deriveKey(from master: SymmetricKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(purpose.utf8), outputByteCount: keyByteCount)
    }

    public static func randomKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// Cryptographically secure random bytes.
    public static func randomBytes(count: Int) -> Data {
        // SymmetricKey draws from the system CSPRNG on all supported platforms.
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
        return key.withUnsafeBytes { Data($0) }
    }

    public static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    public static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == keyByteCount else { throw CryptoError.malformedCiphertext }
        return SymmetricKey(data: data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Purpose labels for sub-keys derived from a profile's data-encryption key.
public enum KeyPurpose {
    public static let userDatabase = "investiq.userdb.v1"
    public static let cacheDatabase = "investiq.cachedb.v1"
}
