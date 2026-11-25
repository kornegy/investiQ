import Foundation
import InvestiQCore

/// File locations inside the app container (Application Support/InvestiQ when sandboxed).
public struct ProfilePaths: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) { self.baseDirectory = baseDirectory }

    /// Default location: `~/Library/Application Support/InvestiQ` (inside the sandbox container).
    public static func applicationSupport() throws -> ProfilePaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return ProfilePaths(baseDirectory: base.appendingPathComponent("InvestiQ", isDirectory: true))
    }

    public var registryURL: URL { baseDirectory.appendingPathComponent("profiles.json") }
    public func directory(for id: ProfileID) -> URL {
        baseDirectory.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id.string, isDirectory: true)
    }
    public func userDatabase(for id: ProfileID) -> URL { directory(for: id).appendingPathComponent("user.iqdb") }
    public func cacheDatabase(for id: ProfileID) -> URL { directory(for: id).appendingPathComponent("cache.iqdb") }
}

/// Non-secret summary shown on the lock screen before unlocking. Stored in plaintext by design:
/// it contains only the display name the user chose, creation date and educational-mode flag.
public struct ProfileSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: ProfileID
    public var displayName: String
    public var createdAt: Date
    public var educationalMode: Bool

    public init(id: ProfileID, displayName: String, createdAt: Date, educationalMode: Bool) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.educationalMode = educationalMode
    }
}

struct ProfileRegistry {
    let url: URL

    func load() throws -> [ProfileSummary] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProfileSummary].self, from: Data(contentsOf: url))
    }

    func save(_ profiles: [ProfileSummary]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(profiles).write(to: url, options: [.atomic])
    }
}
