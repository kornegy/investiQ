import Foundation
import Sodium
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Parameters of a password-based key derivation, stored alongside the wrapped key so they can be
/// upgraded later without breaking existing profiles.
public struct KDFParameters: Codable, Hashable, Sendable {
    public var algorithm: String
    public var opsLimit: Int
    public var memLimitBytes: Int
    public var salt: Data

    public init(algorithm: String, opsLimit: Int, memLimitBytes: Int, salt: Data) {
        self.algorithm = algorithm
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
        self.salt = salt
    }
}

public protocol PasswordKeyDerivation: Sendable {
    func makeParameters() -> KDFParameters
    func deriveKey(password: String, parameters: KDFParameters) throws -> SymmetricKey
}

/// Argon2id (libsodium `crypto_pwhash`, ARGON2ID13) — docs/SECURITY.md §2, ADR-004.
public struct Argon2idKeyDerivation: PasswordKeyDerivation {
    public static let algorithmIdentifier = "argon2id13"
    /// Production parameters: t = 3 passes, m = 64 MiB (above the OWASP minimum of t = 2, m = 19 MiB).
    public static let productionOpsLimit = 3
    public static let productionMemLimitBytes = 64 * 1024 * 1024
    static let saltByteCount = 16

    public let opsLimit: Int
    public let memLimitBytes: Int

    public init(opsLimit: Int = productionOpsLimit, memLimitBytes: Int = productionMemLimitBytes) {
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
    }

    /// Fast parameters for unit tests only (never used by the app).
    public static let testing = Argon2idKeyDerivation(opsLimit: 1, memLimitBytes: 8 * 1024 * 1024)

    public func makeParameters() -> KDFParameters {
        KDFParameters(algorithm: Self.algorithmIdentifier, opsLimit: opsLimit, memLimitBytes: memLimitBytes,
                      salt: CryptoBox.randomBytes(count: Self.saltByteCount))
    }

    public func deriveKey(password: String, parameters: KDFParameters) throws -> SymmetricKey {
        guard parameters.algorithm == Self.algorithmIdentifier, parameters.salt.count == Self.saltByteCount else {
            throw CryptoError.keyDerivationFailed
        }
        // Unicode normalisation so the same visible password always yields the same key.
        let normalized = password.precomposedStringWithCanonicalMapping
        let sodium = Sodium()
        guard let output = sodium.pwHash.hash(outputLength: CryptoBox.keyByteCount,
                                              passwd: Array(normalized.utf8),
                                              salt: Array(parameters.salt),
                                              opsLimit: parameters.opsLimit,
                                              memLimit: parameters.memLimitBytes,
                                              alg: .Argon2ID13) else {
            throw CryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: Data(output))
    }
}
