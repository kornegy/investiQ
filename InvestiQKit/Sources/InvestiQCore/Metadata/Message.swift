import Foundation

/// A typed argument for a localised message; formatted by the UI with the user's locale.
public enum MessageArgument: Hashable, Codable, Sendable {
    case text(String)
    case integer(Int)
    case decimal(Decimal, fractionDigits: Int)
    /// A fraction (0.125 → 12.5 %).
    case percent(Double, fractionDigits: Int)
    case money(Money)
    case date(LocalDate)
    case instant(Date)
    /// Another localisation key (e.g. an enum name).
    case key(String)
}

/// A user-facing message expressed as a localisation key plus arguments (ADR-012).
/// Business logic never produces final UI strings.
public struct Message: Hashable, Codable, Sendable {
    public var key: String
    public var arguments: [MessageArgument]

    public init(_ key: String, _ arguments: [MessageArgument] = []) {
        self.key = key
        self.arguments = arguments
    }
}

/// Neutral, rule-based statuses. InvestiQ never emits BUY/SELL/HOLD (spec §10, ADR-011).
public enum AnalyticalStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case furtherResearchRequired
    case insufficientData
    case elevatedUncertainty
    case elevatedRisk
    case metricsWarrantReview

    public var messageKey: String { "status.\(rawValue)" }
}

/// Lets validation code return `Result<T, Message>` with a localisable failure description.
extension Message: Error {}
