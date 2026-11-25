import Foundation

/// A daily (or intraday) OHLCV bar. Only `close` is required; other fields are optional and never
/// filled with zeros when missing.
public struct PriceBar: Hashable, Codable, Sendable {
    public var date: LocalDate
    public var open: Decimal?
    public var high: Decimal?
    public var low: Decimal?
    public var close: Decimal
    public var volume: Decimal?

    public init(date: LocalDate, open: Decimal? = nil, high: Decimal? = nil, low: Decimal? = nil,
                close: Decimal, volume: Decimal? = nil) {
        self.date = date; self.open = open; self.high = high; self.low = low; self.close = close; self.volume = volume
    }
}

public enum PriceAdjustment: String, Codable, Sendable, CaseIterable {
    /// Raw traded prices.
    case none
    /// Adjusted for splits only.
    case split
    /// Adjusted for splits and dividends (total-return style).
    case splitAndDividend
}

public struct PriceSeries: Hashable, Codable, Sendable {
    public var listing: ListingKey
    public var currency: CurrencyCode
    public var adjustment: PriceAdjustment
    /// Sorted ascending by date, unique dates.
    public var bars: [PriceBar]

    public init(listing: ListingKey, currency: CurrencyCode, adjustment: PriceAdjustment, bars: [PriceBar]) {
        self.listing = listing
        self.currency = currency
        self.adjustment = adjustment
        self.bars = bars.sorted { $0.date < $1.date }
    }

    public var firstDate: LocalDate? { bars.first?.date }
    public var lastDate: LocalDate? { bars.last?.date }

    /// Bars up to and including `date` — the only way forecasting code may access history
    /// (prevents look-ahead bias, docs/FINANCIAL_METHODOLOGY.md §8).
    public func asOf(_ date: LocalDate) -> PriceSeries {
        PriceSeries(listing: listing, currency: currency, adjustment: adjustment, bars: bars.filter { $0.date <= date })
    }

    /// Close on `date` or the most recent close within `maxCarryDays` before it.
    public func close(onOrBefore date: LocalDate, maxCarryDays: Int = 7) -> PriceBar? {
        guard let index = bars.lastIndex(where: { $0.date <= date }) else { return nil }
        let bar = bars[index]
        return bar.date.days(to: date) <= maxCarryDays ? bar : nil
    }
}

public struct Quote: Hashable, Codable, Sendable {
    public var listing: ListingKey
    public var price: Decimal
    public var currency: CurrencyCode
    public var previousClose: Decimal?
    public var change: Decimal?
    public var changePercent: Decimal?
    public var dayHigh: Decimal?
    public var dayLow: Decimal?
    public var volume: Decimal?

    public init(listing: ListingKey, price: Decimal, currency: CurrencyCode, previousClose: Decimal? = nil,
                change: Decimal? = nil, changePercent: Decimal? = nil, dayHigh: Decimal? = nil,
                dayLow: Decimal? = nil, volume: Decimal? = nil) {
        self.listing = listing
        self.price = price
        self.currency = currency
        self.previousClose = previousClose
        self.change = change
        self.changePercent = changePercent
        self.dayHigh = dayHigh
        self.dayLow = dayLow
        self.volume = volume
    }
}

/// An exchange rate: `rate` units of `quote` per 1 unit of `base` on `date`.
public struct ExchangeRate: Hashable, Codable, Sendable {
    public var base: CurrencyCode
    public var quote: CurrencyCode
    public var rate: Decimal
    public var date: LocalDate
    public init(base: CurrencyCode, quote: CurrencyCode, rate: Decimal, date: LocalDate) {
        self.base = base; self.quote = quote; self.rate = rate; self.date = date
    }
    public var inverted: ExchangeRate { ExchangeRate(base: quote, quote: base, rate: 1 / rate, date: date) }
}

public enum CorporateActionKind: String, Codable, Sendable, CaseIterable { case split, reverseSplit, spinOff, merger, delisting }

public struct CorporateAction: Hashable, Codable, Sendable {
    public var instrumentID: InstrumentID?
    public var listing: ListingKey?
    public var effectiveDate: LocalDate
    public var kind: CorporateActionKind
    public var ratioNumerator: Int?
    public var ratioDenominator: Int?
    public init(instrumentID: InstrumentID? = nil, listing: ListingKey? = nil, effectiveDate: LocalDate,
                kind: CorporateActionKind, ratioNumerator: Int? = nil, ratioDenominator: Int? = nil) {
        self.instrumentID = instrumentID; self.listing = listing; self.effectiveDate = effectiveDate
        self.kind = kind; self.ratioNumerator = ratioNumerator; self.ratioDenominator = ratioDenominator
    }
}

public struct DividendEvent: Hashable, Codable, Sendable {
    public var exDate: LocalDate
    public var payDate: LocalDate?
    public var amountPerShare: Decimal
    public var currency: CurrencyCode
    public init(exDate: LocalDate, payDate: LocalDate? = nil, amountPerShare: Decimal, currency: CurrencyCode) {
        self.exDate = exDate; self.payDate = payDate; self.amountPerShare = amountPerShare; self.currency = currency
    }
}
