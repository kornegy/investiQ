import Foundation

public enum TransactionType: String, Codable, Sendable, CaseIterable {
    case buy, sell, dividend, coupon, interest, fee, tax, deposit, withdrawal, split, fxConversion, bondRedemption

    /// Types that change the quantity of an instrument.
    public var affectsQuantity: Bool { [.buy, .sell, .split, .bondRedemption].contains(self) }
    /// Types that require an instrument reference.
    public var requiresInstrument: Bool { [.buy, .sell, .dividend, .coupon, .split, .bondRedemption].contains(self) }
    /// External cash flows (money entering/leaving the portfolio) — never counted as profit.
    public var isExternalFlow: Bool { self == .deposit || self == .withdrawal }

    /// Processing order for same-day transactions (docs/FINANCIAL_METHODOLOGY.md §1).
    public var sameDayOrder: Int {
        switch self {
        case .split: return 0
        case .deposit, .fxConversion: return 1
        case .buy: return 2
        case .sell, .bondRedemption: return 3
        case .dividend, .coupon, .interest: return 4
        case .fee, .tax: return 5
        case .withdrawal: return 6
        }
    }
}

public enum TransactionSource: String, Codable, Sendable, CaseIterable {
    case manual, csvImport, simulator, demo
}

/// A single ledger entry. Field usage per type is enforced by `TransactionValidator`.
///
/// * `buy`/`sell`: `quantity`, `price` (per unit, `currency`), optional `fees`, `accruedInterest` (bonds)
/// * `dividend`/`coupon`/`interest`: `amount` = gross income, `taxWithheld`
/// * `fee`/`tax`/`deposit`/`withdrawal`: `amount`
/// * `split`: `splitNumerator`:`splitDenominator` (4:1 → 4, 1)
/// * `fxConversion`: `amount` in `currency` → `counterAmount` in `counterCurrency`, optional `fees`
/// * `bondRedemption`: `quantity`, `price` (redemption price per unit)
public struct Transaction: Identifiable, Hashable, Codable, Sendable {
    public var id: TransactionID
    public var portfolioID: PortfolioID
    public var type: TransactionType
    public var instrumentID: InstrumentID?
    public var listingID: ListingID?
    public var tradeDate: LocalDate
    public var settleDate: LocalDate?
    public var quantity: Decimal?
    public var price: Decimal?
    public var amount: Decimal?
    public var currency: CurrencyCode
    public var fees: Decimal
    public var feeCurrency: CurrencyCode?
    public var taxWithheld: Decimal
    /// Accrued interest paid (buy) or received (sell) for bonds, in `currency`.
    public var accruedInterest: Decimal?
    /// Units of the portfolio base currency per 1 unit of `currency` on the trade date.
    public var fxRateToBase: Decimal?
    public var counterCurrency: CurrencyCode?
    public var counterAmount: Decimal?
    public var splitNumerator: Int?
    public var splitDenominator: Int?
    public var notes: String?
    public var source: TransactionSource
    /// Identifier from an import source; makes CSV import idempotent.
    public var externalRef: String?
    public var createdAt: Date

    public init(id: TransactionID = TransactionID(), portfolioID: PortfolioID, type: TransactionType,
                instrumentID: InstrumentID? = nil, listingID: ListingID? = nil, tradeDate: LocalDate,
                settleDate: LocalDate? = nil, quantity: Decimal? = nil, price: Decimal? = nil,
                amount: Decimal? = nil, currency: CurrencyCode, fees: Decimal = 0, feeCurrency: CurrencyCode? = nil,
                taxWithheld: Decimal = 0, accruedInterest: Decimal? = nil, fxRateToBase: Decimal? = nil,
                counterCurrency: CurrencyCode? = nil, counterAmount: Decimal? = nil,
                splitNumerator: Int? = nil, splitDenominator: Int? = nil, notes: String? = nil,
                source: TransactionSource = .manual, externalRef: String? = nil, createdAt: Date) {
        self.id = id
        self.portfolioID = portfolioID
        self.type = type
        self.instrumentID = instrumentID
        self.listingID = listingID
        self.tradeDate = tradeDate
        self.settleDate = settleDate
        self.quantity = quantity
        self.price = price
        self.amount = amount
        self.currency = currency
        self.fees = fees
        self.feeCurrency = feeCurrency
        self.taxWithheld = taxWithheld
        self.accruedInterest = accruedInterest
        self.fxRateToBase = fxRateToBase
        self.counterCurrency = counterCurrency
        self.counterAmount = counterAmount
        self.splitNumerator = splitNumerator
        self.splitDenominator = splitDenominator
        self.notes = notes
        self.source = source
        self.externalRef = externalRef
        self.createdAt = createdAt
    }

    /// Effective fee currency (defaults to the transaction currency).
    public var effectiveFeeCurrency: CurrencyCode { feeCurrency ?? currency }
}

public enum TransactionValidationError: Error, Equatable, Sendable {
    case missingField(String)
    case nonPositive(String)
    case negative(String)
    case invalidSplitRatio
    case sameCurrencyConversion
    case unsupportedFeeCurrency
    case notesTooLong
    case taxExceedsIncome
}

/// Validates the per-type field rules. The database schema enforces the same rules with CHECK
/// constraints as a second line of defence.
public enum TransactionValidator {
    public static let maximumNotesLength = 2_000

    public static func validate(_ t: Transaction, baseCurrency: CurrencyCode) throws {
        func require<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw TransactionValidationError.missingField(name) }
            return value
        }
        func positive(_ value: Decimal?, _ name: String) throws {
            let v = try require(value, name)
            guard v > 0 else { throw TransactionValidationError.nonPositive(name) }
        }
        guard t.fees >= 0 else { throw TransactionValidationError.negative("fees") }
        guard t.taxWithheld >= 0 else { throw TransactionValidationError.negative("taxWithheld") }
        if let notes = t.notes, notes.count > maximumNotesLength { throw TransactionValidationError.notesTooLong }
        if t.type.requiresInstrument { _ = try require(t.instrumentID, "instrumentID") }
        if let rate = t.fxRateToBase, rate <= 0 { throw TransactionValidationError.nonPositive("fxRateToBase") }
        if let feeCurrency = t.feeCurrency, feeCurrency != t.currency, feeCurrency != baseCurrency {
            throw TransactionValidationError.unsupportedFeeCurrency
        }
        switch t.type {
        case .buy, .sell, .bondRedemption:
            try positive(t.quantity, "quantity")
            let price = try require(t.price, "price")
            guard price >= 0 else { throw TransactionValidationError.negative("price") }
            if let accrued = t.accruedInterest, accrued < 0 { throw TransactionValidationError.negative("accruedInterest") }
        case .dividend, .coupon, .interest:
            try positive(t.amount, "amount")
            if let gross = t.amount, t.taxWithheld > gross { throw TransactionValidationError.taxExceedsIncome }
        case .fee, .tax, .deposit, .withdrawal:
            try positive(t.amount, "amount")
        case .split:
            guard let n = t.splitNumerator, let d = t.splitDenominator, n > 0, d > 0, n != d else {
                throw TransactionValidationError.invalidSplitRatio
            }
        case .fxConversion:
            try positive(t.amount, "amount")
            try positive(t.counterAmount, "counterAmount")
            let counter = try require(t.counterCurrency, "counterCurrency")
            guard counter != t.currency else { throw TransactionValidationError.sameCurrencyConversion }
        }
    }
}
