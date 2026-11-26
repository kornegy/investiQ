import Foundation
import InvestiQCore
import InvestiQSecurity
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum DatabaseContentKind: UInt16, Sendable {
    case user = 1
    case cache = 2
}

public enum EncryptedFileError: Error, Equatable, Sendable {
    case notAnInvestiQDatabase
    case unsupportedFormatVersion(UInt16)
    case wrongContentKind
    case profileMismatch
    case decryptionFailed
    case writeFailed(String)
}

/// On-disk container for an encrypted SQLite image (format `IQDB` v1, docs/SECURITY.md §3).
///
/// Layout: magic(4) ‖ version(2) ‖ kind(2) ‖ profileUUID(16) ‖ schemaVersion(8) ‖ AES-GCM combined
/// (nonce ‖ ciphertext ‖ tag), with bytes 0…31 as associated data.
public struct EncryptedDatabaseFile: Sendable {
    static let magic = Data("IQDB".utf8)
    static let formatVersion: UInt16 = 1
    static let headerLength = 32

    public let url: URL
    public let kind: DatabaseContentKind
    public let profileID: ProfileID
    private let key: SymmetricKey

    public init(url: URL, kind: DatabaseContentKind, profileID: ProfileID, key: SymmetricKey) {
        self.url = url
        self.kind = kind
        self.profileID = profileID
        self.key = key
    }

    /// The previous generation, kept for crash recovery.
    public var backupURL: URL { url.appendingPathExtension("bak") }

    func header(schemaVersion: Int) -> Data {
        var header = Data()
        header.append(Self.magic)
        header.append(contentsOf: withUnsafeBytes(of: Self.formatVersion.bigEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: kind.rawValue.bigEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: profileID.rawValue.uuid, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt64(schemaVersion).bigEndian, Array.init))
        return header
    }

    /// Encrypts `image` and atomically replaces the file, keeping the previous generation as `.bak`.
    public func write(image: Data, schemaVersion: Int) throws {
        let header = header(schemaVersion: schemaVersion)
        let sealed = try CryptoBox.seal(image, key: key, associatedData: header)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: header + sealed,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw EncryptedFileError.writeFailed("could not create temporary file")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            // rename(2) is atomic within one directory/volume.
            if fileManager.fileExists(atPath: url.path) {
                if rename(url.path, backupURL.path) != 0 { throw EncryptedFileError.writeFailed("rotate failed: \(errno)") }
            }
            if rename(temporary.path, url.path) != 0 { throw EncryptedFileError.writeFailed("rename failed: \(errno)") }
        } catch {
            try? fileManager.removeItem(at: temporary) // best-effort cleanup of the temp file
            throw error
        }
    }

    /// Reads and decrypts the database image. Returns `nil` when no file exists yet.
    /// If the main file is missing but a previous generation exists (crash between the two renames),
    /// the previous generation is used.
    public func read() throws -> (image: Data, schemaVersion: Int)? {
        let fileManager = FileManager.default
        let source: URL
        if fileManager.fileExists(atPath: url.path) {
            source = url
        } else if fileManager.fileExists(atPath: backupURL.path) {
            source = backupURL
        } else {
            return nil
        }
        return try decode(try Data(contentsOf: source))
    }

    func decode(_ data: Data) throws -> (image: Data, schemaVersion: Int) {
        guard data.count > Self.headerLength, data.prefix(4) == Self.magic else { throw EncryptedFileError.notAnInvestiQDatabase }
        let bytes = [UInt8](data.prefix(Self.headerLength))
        let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard version == Self.formatVersion else { throw EncryptedFileError.unsupportedFormatVersion(version) }
        let kindRaw = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard kindRaw == kind.rawValue else { throw EncryptedFileError.wrongContentKind }
        let uuidBytes = Array(bytes[8..<24])
        let uuid = UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3], uuidBytes[4], uuidBytes[5],
                               uuidBytes[6], uuidBytes[7], uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                               uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
        guard uuid == profileID.rawValue else { throw EncryptedFileError.profileMismatch }
        let schemaVersion = bytes[24..<32].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let header = data.prefix(Self.headerLength)
        do {
            let image = try CryptoBox.open(data.dropFirst(Self.headerLength), key: key, associatedData: Data(header))
            return (image, Int(schemaVersion))
        } catch {
            throw EncryptedFileError.decryptionFailed
        }
    }
}
