import Foundation

/// Where a value came from.
public struct DataSourceInfo: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Stable identifier (`alphavantage`, `ecb`, `manual`, `demo`, …).
    public var id: String
    /// Human-readable provider name (proper noun, not localised).
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public var description: String { name }

    public static let manual = DataSourceInfo(id: "manual", name: "Manual entry")
    public static let demo = DataSourceInfo(id: "demo", name: "InvestiQ demo data (synthetic)")
    public static let computed = DataSourceInfo(id: "computed", name: "InvestiQ calculation")
}

/// Timeliness of a value. Free data is never labelled `realtime` (docs/DATA_PROVIDERS.md §1).
public enum DelayStatus: Hashable, Codable, Sendable {
    case realtime
    case delayed(minutes: Int)
    case endOfDay
    /// Served from cache within its freshness window.
    case cached
    /// Served from cache after its freshness window (e.g. during an outage).
    case stale
    case manual
    /// Synthetic demo data.
    case synthetic
}

public enum DataQualityStatus: String, Codable, Sendable, CaseIterable {
    case validated, unvalidated, conflicting, partial, suspect
}

public struct DataMetadata: Hashable, Codable, Sendable {
    public var source: DataSourceInfo
    public var retrievedAt: Date
    public var marketTimestamp: Date?
    public var currency: CurrencyCode?
    public var delay: DelayStatus
    public var quality: DataQualityStatus
    /// Additional notes, e.g. the conflicting value from another source.
    public var conflicts: [ConflictingValue]

    public init(source: DataSourceInfo, retrievedAt: Date, marketTimestamp: Date? = nil, currency: CurrencyCode? = nil,
                delay: DelayStatus, quality: DataQualityStatus, conflicts: [ConflictingValue] = []) {
        self.source = source
        self.retrievedAt = retrievedAt
        self.marketTimestamp = marketTimestamp
        self.currency = currency
        self.delay = delay
        self.quality = quality
        self.conflicts = conflicts
    }
}

public struct ConflictingValue: Hashable, Codable, Sendable {
    public var source: DataSourceInfo
    public var value: Decimal
    public init(source: DataSourceInfo, value: Decimal) { self.source = source; self.value = value }
}

/// A value together with its provenance (spec §15).
public struct Sourced<Value: Sendable>: Sendable {
    public var value: Value
    public var metadata: DataMetadata
    public init(_ value: Value, metadata: DataMetadata) { self.value = value; self.metadata = metadata }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> Sourced<T> {
        Sourced<T>(try transform(value), metadata: metadata)
    }
}

extension Sourced: Equatable where Value: Equatable {}
extension Sourced: Hashable where Value: Hashable {}
extension Sourced: Codable where Value: Codable {}
