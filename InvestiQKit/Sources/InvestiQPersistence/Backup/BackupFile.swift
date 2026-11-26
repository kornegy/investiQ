import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import InvestiQCore
import InvestiQSecurity

/// Encrypted backup file (`.iqbackup`, docs/SECURITY.md §5).
///
/// Layout: `"IQBK"` · format version (UInt16 BE) · header length (UInt32 BE) · header JSON · AES-256-GCM
/// box of the user-database image. The header (KDF parameters, schema version, creation time) is the
/// associated data, so it cannot be altered without detection. The key is derived with Argon2id from a
/// backup passphrase chosen by the user, then HKDF with purpose `investiq.backup.v1`. API keys and the
/// login envelope are never part of a backup.
public enum BackupFile {
    static let magic = Data("IQBK".utf8)
    static let formatVersion: UInt16 = 1
    static let purpose = "investiq.backup.v1"
    /// Upper bound accepted on restore (the user database is small; this rejects absurd inputs early).
    public static let maximumSize = 512 * 1024 * 1024

    public struct Header: Codable, Sendable, Equatable {
        public var kdf: KDFParameters
        public var schemaVersion: Int
        public var createdAt: Date
        public var contents: String
    }

    public enum BackupError: Error, Equatable, Sendable {
        case notABackup
        case unsupportedVersion
        case wrongPassphraseOrDamaged
        case tooLarge
    }

    public static func make(image: Data, schemaVersion: Int, passphrase: String, derivation: any PasswordKeyDerivation, now: Date) throws -> Data {
        let parameters = derivation.makeParameters()
        let key = CryptoBox.deriveKey(from: try derivation.deriveKey(password: passphrase, parameters: parameters), purpose: purpose)
        let header = Header(kdf: parameters, schemaVersion: schemaVersion, createdAt: now, contents: "userDatabase")
        let headerData = try encoder.encode(header)
        var prefix = magic
        prefix.append(contentsOf: withUnsafeBytes(of: formatVersion.bigEndian, Array.init))
        prefix.append(contentsOf: withUnsafeBytes(of: UInt32(headerData.count).bigEndian, Array.init))
        prefix.append(headerData)
        return prefix + (try CryptoBox.seal(image, key: key, associatedData: prefix))
    }

    /// Reads the header without decrypting (shown before asking for the passphrase).
    public static func header(of data: Data) throws -> Header {
        try split(data).header
    }

    public static func open(_ data: Data, passphrase: String, derivation: any PasswordKeyDerivation) throws -> (header: Header, image: Data) {
        let parts = try split(data)
        let key = CryptoBox.deriveKey(from: try derivation.deriveKey(password: passphrase, parameters: parts.header.kdf), purpose: purpose)
        do {
            return (parts.header, try CryptoBox.open(parts.ciphertext, key: key, associatedData: parts.prefix))
        } catch {
            throw BackupError.wrongPassphraseOrDamaged
        }
    }

    static func split(_ data: Data) throws -> (prefix: Data, header: Header, ciphertext: Data) {
        guard data.count <= maximumSize else { throw BackupError.tooLarge }
        let bytes = [UInt8](data)
        guard bytes.count > 10, Data(bytes[0..<4]) == magic else { throw BackupError.notABackup }
        let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard version == formatVersion else { throw BackupError.unsupportedVersion }
        let length = Int(UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9]))
        guard length > 0, length < 64 * 1024, bytes.count > 10 + length else { throw BackupError.notABackup }
        let headerData = Data(bytes[10..<(10 + length)])
        guard let header = try? decoder.decode(Header.self, from: headerData) else { throw BackupError.notABackup }
        // Untrusted input: refuse KDF parameters that would let a crafted file exhaust CPU or memory.
        guard (1...10).contains(header.kdf.opsLimit), (8 * 1024 * 1024...1024 * 1024 * 1024).contains(header.kdf.memLimitBytes),
              header.kdf.salt.count == 16 else { throw BackupError.notABackup }
        return (Data(bytes[0..<(10 + length)]), header, Data(bytes[(10 + length)...]))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
