import Foundation

/// Source of the current time. Logic never calls `Date()` directly so tests are deterministic.
public protocol TimeProvider: Sendable {
    func now() -> Date
}

public struct SystemTimeProvider: TimeProvider {
    public init() {}
    public func now() -> Date { Date() }
}

/// A controllable clock for tests and the historical simulator.
public final class ManualTimeProvider: TimeProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { current = start }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

public extension TimeProvider {
    func today(in timeZone: TimeZone = .current) -> LocalDate { LocalDate(now(), timeZone: timeZone) }
}

/// ISO-8601 helpers for persisted instants (always UTC, second precision).
public enum InstantCoding {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    public static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
