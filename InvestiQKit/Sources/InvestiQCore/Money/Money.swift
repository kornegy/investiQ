import Foundation

/// An exact monetary amount in a specific currency.
public struct Money: Hashable, Codable, Sendable, CustomStringConvertible {
    public var amount: Decimal
    public var currency: CurrencyCode

    public init(_ amount: Decimal, _ currency: CurrencyCode) {
        self.amount = amount
        self.currency = currency
    }

    public static func zero(_ currency: CurrencyCode) -> Money { Money(0, currency) }

    public var isZero: Bool { amount == 0 }
    public var isNegative: Bool { amount < 0 }

    public func adding(_ other: Money) throws -> Money {
        guard other.currency == currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        return Money(amount + other.amount, currency)
    }

    public func subtracting(_ other: Money) throws -> Money {
        guard other.currency == currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        return Money(amount - other.amount, currency)
    }

    public func multiplied(by factor: Decimal) -> Money { Money(amount * factor, currency) }

    /// Converts using `rate` = units of `target` per 1 unit of `currency`.
    public func converted(to target: CurrencyCode, rate: Decimal) -> Money {
        target == currency ? self : Money(amount * rate, target)
    }

    public var negated: Money { Money(-amount, currency) }

    public var description: String { "\(amount.canonicalString) \(currency.rawValue)" }
}

public enum MoneyError: Error, Equatable, Sendable {
    case currencyMismatch(CurrencyCode, CurrencyCode)
    case missingExchangeRate(from: CurrencyCode, to: CurrencyCode)
}
