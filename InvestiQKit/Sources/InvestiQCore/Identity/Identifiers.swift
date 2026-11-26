import Foundation

/// Strongly typed UUID-based identifiers.
public protocol UUIDIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension UUIDIdentifier {
    init() { self.init(rawValue: UUID()) }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(rawValue: uuid)
    }
    var string: String { rawValue.uuidString }
    var description: String { rawValue.uuidString }
}

public struct ProfileID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct InstrumentID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ListingID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct PortfolioID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct TransactionID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct WatchlistID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ForecastID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct NotificationRuleID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct GoalID: UUIDIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

/// International Securities Identification Number (ISO 6166), validated including the check digit.
public struct ISIN: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard ISIN.isValid(candidate) else { return nil }
        self.rawValue = candidate
    }

    public var countryCode: String { String(rawValue.prefix(2)) }
    public var description: String { rawValue }

    /// Structure: 2 letters, 9 alphanumerics, 1 check digit (Luhn over the letter-expanded digits).
    public static func isValid(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count == 12,
              chars[0].isASCII, chars[0].isLetter, chars[1].isASCII, chars[1].isLetter,
              chars[2..<11].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let check = chars[11].wholeNumberValue, chars[11].isASCII else { return false }
        var digits: [Int] = []
        for char in chars[0..<11] {
            if let value = char.wholeNumberValue {
                digits.append(value)
            } else if let ascii = char.uppercased().unicodeScalars.first?.value {
                let value = Int(ascii) - 55 // A = 10 … Z = 35
                digits.append(value / 10)
                digits.append(value % 10)
            }
        }
        // Luhn: double every second digit from the right (the check digit is excluded).
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 0 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return (10 - sum % 10) % 10 == check
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let isin = ISIN(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISIN")
        }
        self = isin
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// ISO 10383 Market Identifier Code (e.g. `XPRA` Prague, `XETR` Xetra, `XNYS` NYSE).
public struct MIC: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard candidate.count == 4, candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        self.rawValue = candidate
    }
    public var description: String { rawValue }
}

/// A trading symbol on a specific venue. Never used as a global instrument identifier (ADR-006).
public struct Ticker: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:^/"))
        guard (1...24).contains(candidate.count),
              candidate.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        self.rawValue = candidate
    }
    public var description: String { rawValue }
}
