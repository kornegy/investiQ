import Foundation
import InvestiQCore

/// An explainable analytical result (spec §13): value + inputs + method + date + limitations +
/// completeness + plain-language explanation. Missing inputs make the value `nil`, never zero.
public struct AnalyticResult<Value: Sendable & Equatable>: Sendable, Equatable {
    /// Method identifier from docs/FINANCIAL_METHODOLOGY.md (e.g. "M-VOL-1").
    public var methodID: String
    public var value: Value?
    public var inputs: [AnalyticInput]
    public var sources: [DataSourceInfo]
    public var calculatedAt: Date
    public var limitations: [Message]
    /// Fraction of required inputs that were available (0…1).
    public var completeness: Double
    public var explanation: Message?

    public init(methodID: String, value: Value?, inputs: [AnalyticInput] = [], sources: [DataSourceInfo] = [],
                calculatedAt: Date, limitations: [Message] = [], completeness: Double, explanation: Message? = nil) {
        self.methodID = methodID
        self.value = value
        self.inputs = inputs
        self.sources = sources
        self.calculatedAt = calculatedAt
        self.limitations = limitations
        self.completeness = max(0, min(1, completeness))
        self.explanation = explanation
    }

    public var isAvailable: Bool { value != nil }
}

public struct AnalyticInput: Sendable, Hashable {
    public var nameKey: String
    public var value: String?
    public init(nameKey: String, value: String?) { self.nameKey = nameKey; self.value = value }
}
