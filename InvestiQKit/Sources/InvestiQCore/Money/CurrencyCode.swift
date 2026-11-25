import Foundation

/// ISO 4217 alphabetic currency code (e.g. `CZK`, `EUR`, `USD`).
///
/// Validation is structural (three uppercase ASCII letters); the list of currencies the app
/// supports as *base* currencies is `CurrencyCode.supportedBaseCurrencies`.
public struct CurrencyCode: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count == 3, trimmed.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return nil
        }
        self.rawValue = trimmed
    }

    /// Creates a code from a literal known to be valid. Only for compile-time constants.
    private init(validated: String) { self.rawValue = validated }

    public static let czk = CurrencyCode(validated: "CZK")
    public static let eur = CurrencyCode(validated: "EUR")
    public static let usd = CurrencyCode(validated: "USD")
    public static let gbp = CurrencyCode(validated: "GBP")
    public static let chf = CurrencyCode(validated: "CHF")
    public static let pln = CurrencyCode(validated: "PLN")

    /// Currencies the user can choose as the primary/base currency (spec §28).
    public static let supportedBaseCurrencies: [CurrencyCode] = [.czk, .eur, .usd]

    /// Number of minor units used for *display rounding*. Internal values are never rounded.
    public var minorUnits: Int {
        switch rawValue {
        case "JPY", "KRW", "ISK", "CLP": return 0
        case "BHD", "KWD", "OMR", "JOD", "TND": return 3
        default: return 2
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: CurrencyCode, rhs: CurrencyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let code = CurrencyCode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid currency code '\(raw)'")
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
