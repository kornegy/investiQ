import Foundation
import InvestiQCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum KeyEnvelopeError: Error, Equatable, Sendable {
    case wrongPassword
    case unsupportedVersion(Int)
    case corrupted
}

/// A profile's data-encryption key (DEK) wrapped with a key derived from the user's password.
/// A wrong password fails AES-GCM authentication, so no password hash is stored (docs/SECURITY.md §3).
public struct KeyEnvelope: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profileID: String
    public var kdf: KDFParameters
    public var wrappedKey: Data
    public var createdAt: Date

    public static func create(dataKey: SymmetricKey, password: String, profileID: ProfileID,
                              derivation: any PasswordKeyDerivation, now: Date) throws -> KeyEnvelope {
        let parameters = derivation.makeParameters()
        let kek = try derivation.deriveKey(password: password, parameters: parameters)
        let aad = associatedData(version: currentVersion, profileID: profileID.string)
        let wrapped = try CryptoBox.seal(CryptoBox.keyData(dataKey), key: kek, associatedData: aad)
        return KeyEnvelope(version: currentVersion, profileID: profileID.string, kdf: parameters,
                           wrappedKey: wrapped, createdAt: now)
    }

    public func unwrap(password: String, derivation: any PasswordKeyDerivation) throws -> SymmetricKey {
        guard version == Self.currentVersion else { throw KeyEnvelopeError.unsupportedVersion(version) }
        let kek = try derivation.deriveKey(password: password, parameters: kdf)
        do {
            let raw = try CryptoBox.open(wrappedKey, key: kek, associatedData: Self.associatedData(version: version, profileID: profileID))
            return try CryptoBox.key(from: raw)
        } catch CryptoError.authenticationFailed {
            throw KeyEnvelopeError.wrongPassword
        } catch {
            throw KeyEnvelopeError.corrupted
        }
    }

    static func associatedData(version: Int, profileID: String) -> Data {
        Data("investiq.key-envelope.v\(version).\(profileID)".utf8)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> KeyEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(KeyEnvelope.self, from: data) } catch { throw KeyEnvelopeError.corrupted }
    }
}
