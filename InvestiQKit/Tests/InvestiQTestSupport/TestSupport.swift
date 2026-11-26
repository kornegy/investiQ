import Foundation
import InvestiQCore

/// A unique temporary directory removed on deinit.
public final class TemporaryDirectory {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("investiq-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public extension LocalDate {
    /// Test helper: `LocalDate.d("2024-01-31")`. Crashes on invalid literals (tests only).
    static func d(_ iso: String) -> LocalDate {
        guard let date = LocalDate(iso: iso) else { preconditionFailure("invalid date literal \(iso)") }
        return date
    }
}

public extension Decimal {
    /// Test helper for exact decimal literals: `Decimal.n("0.1")`.
    static func n(_ text: String) -> Decimal {
        guard let value = DecimalSupport.parse(text) else { preconditionFailure("invalid decimal literal \(text)") }
        return value
    }
}

public extension Date {
    static func utc(_ iso: String) -> Date {
        guard let date = InstantCoding.date(from: iso) else { preconditionFailure("invalid instant \(iso)") }
        return date
    }
}

public let fixedNow = Date.utc("2026-11-24T12:00:00Z")
