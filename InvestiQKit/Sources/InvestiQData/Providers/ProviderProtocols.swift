import Foundation
import InvestiQCore

/// Why a provider request failed. Mapped to UI states (error, offline, stale data).
public enum ProviderFailure: Error, Equatable, Sendable {
    case offline
    case timedOut
    case connectionFailed
    case rateLimited(retryAfter: Double?)
    case quotaExhausted
    case unauthorized
    case missingAPIKey
    /// The endpoint or market is not part of the user's plan (e.g. Finnhub candles on free plans).
    case notSupported
    case notFound
    case invalidResponse(String)
    case serverError(Int)
    case cancelled
    case misconfigured(String)

    /// Failures after which the next provider in the fallback chain should be tried.
    public var allowsFallback: Bool {
        switch self {
        case .cancelled, .misconfigured: return false
        default: return true
        }
    }
}

public enum ProviderCapability: String, Sendable, CaseIterable, Codable {
    case search, quotes, history, fundamentals, news, bonds, etfs, exchangeRates, macro, earningsCalendar
}

/// Static description of a provider adapter (docs/DATA_PROVIDERS.md §2).
public struct ProviderInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var capabilities: Set<ProviderCapability>
    public var limits: ProviderLimits
    public var requiresAPIKey: Bool
    /// Delay class of quotes on the plan the app assumes (free tiers): never real-time by default.
    public var quoteDelay: DelayStatus
    public var termsURL: URL?
    public var signupURL: URL?
    /// Free-text coverage hint key (localised by the UI), e.g. `provider.coverage.us`.
    public var coverageKey: String
    /// Whether the provider's terms allow storing responses locally (encrypted cache).
    public var allowsLocalCaching: Bool

    public init(id: String, name: String, capabilities: Set<ProviderCapability>, limits: ProviderLimits,
                requiresAPIKey: Bool, quoteDelay: DelayStatus, termsURL: URL?, signupURL: URL?, coverageKey: String,
                allowsLocalCaching: Bool = true) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.limits = limits
        self.requiresAPIKey = requiresAPIKey
        self.quoteDelay = quoteDelay
        self.termsURL = termsURL
        self.signupURL = signupURL
        self.coverageKey = coverageKey
        self.allowsLocalCaching = allowsLocalCaching
    }

    public var source: DataSourceInfo { DataSourceInfo(id: id, name: name) }
}

public protocol DataProvider: Sendable {
    var info: ProviderInfo { get }
}

/// Search hit returned by a provider; becomes an `Instrument` + `Listing` when the user adds it.
public struct InstrumentSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(providerID)|\(symbol)" }
    public var providerID: String
    /// Symbol in the provider's own notation (used for later requests).
    public var symbol: String
    public var name: String
    public var kind: InstrumentKind?
    public var isin: ISIN?
    public var mic: MIC?
    public var exchangeName: String?
    public var ticker: Ticker?
    public var currency: CurrencyCode?
    public var country: String?
    public var sector: String?

    public init(providerID: String, symbol: String, name: String, kind: InstrumentKind?, isin: ISIN? = nil,
                mic: MIC? = nil, exchangeName: String? = nil, ticker: Ticker? = nil, currency: CurrencyCode? = nil,
                country: String? = nil, sector: String? = nil) {
        self.providerID = providerID
        self.symbol = symbol
        self.name = name
        self.kind = kind
        self.isin = isin
        self.mic = mic
        self.exchangeName = exchangeName
        self.ticker = ticker
        self.currency = currency
        self.country = country
        self.sector = sector
    }
}

/// A listing as addressed by one provider.
public struct ProviderSymbol: Sendable, Hashable {
    public var providerID: String
    public var symbol: String
    public var listing: ListingKey
    public var currency: CurrencyCode?
    public init(providerID: String, symbol: String, listing: ListingKey, currency: CurrencyCode? = nil) {
        self.providerID = providerID
        self.symbol = symbol
        self.listing = listing
        self.currency = currency
    }
}

public struct DateRange: Sendable, Hashable {
    public var start: LocalDate
    public var end: LocalDate
    public init(start: LocalDate, end: LocalDate) { self.start = start; self.end = end }
}

public protocol MarketDataProvider: DataProvider {
    func search(_ query: String) async throws -> [InstrumentSearchResult]
    func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote>
    func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries>
}

public protocol FundamentalsProvider: DataProvider {
    func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot>
}

public protocol ExchangeRateProvider: DataProvider {
    /// Rates published on or before `date` for `base` → each of `quotes`.
    func rates(base: CurrencyCode, quotes: [CurrencyCode], on date: LocalDate) async throws -> Sourced<[ExchangeRate]>
}

public struct MacroObservation: Sendable, Hashable, Codable {
    public var date: LocalDate
    public var value: Double?
    public init(date: LocalDate, value: Double?) { self.date = date; self.value = value }
}

public protocol MacroeconomicDataProvider: DataProvider {
    func series(id: String, range: DateRange) async throws -> Sourced<[MacroObservation]>
}

/// Contract for live bond terms/quotes. No free source exists for EU/CZ bonds (DATA_PROVIDERS.md §2);
/// v1 ships the protocol as an extension point plus demo/manual data.
public protocol BondDataProvider: DataProvider {
    func bondDetails(isin: ISIN) async throws -> Sourced<BondDetails>
    func bondQuote(isin: ISIN) async throws -> Sourced<Quote>
}

/// Contract for UCITS ETF data (holdings, TER, KID). Extension point; no free source in v1.
public protocol ETFDataProvider: DataProvider {
    func etfDetails(isin: ISIN) async throws -> Sourced<ETFDetails>
}

/// News items as delivered by a provider, before deduplication/classification (Phase 5).
public struct RawNewsItem: Sendable, Hashable, Codable {
    public var providerID: String
    public var headline: String
    public var summary: String?
    public var url: URL
    public var sourceName: String
    public var publishedAt: Date
    public var relatedSymbols: [String]
    public var providerCategory: String?
    public var language: String?

    public init(providerID: String, headline: String, summary: String?, url: URL, sourceName: String, publishedAt: Date,
                relatedSymbols: [String] = [], providerCategory: String? = nil, language: String? = nil) {
        self.providerID = providerID
        self.headline = headline
        self.summary = summary
        self.url = url
        self.sourceName = sourceName
        self.publishedAt = publishedAt
        self.relatedSymbols = relatedSymbols
        self.providerCategory = providerCategory
        self.language = language
    }
}

public protocol NewsProvider: DataProvider {
    func latestNews(symbols: [String], limit: Int) async throws -> [RawNewsItem]
}

/// A scheduled earnings release (Finnhub earnings calendar).
public struct EarningsEvent: Sendable, Hashable, Codable {
    public var symbol: String
    public var date: LocalDate
    public var hour: String?
    public var epsEstimate: Decimal?
    public var epsActual: Decimal?
    public init(symbol: String, date: LocalDate, hour: String?, epsEstimate: Decimal?, epsActual: Decimal?) {
        self.symbol = symbol; self.date = date; self.hour = hour; self.epsEstimate = epsEstimate; self.epsActual = epsActual
    }
}

/// Upcoming dividend dates (ex-date and payment date). No v1 free adapter supplies future payment dates;
/// the demo provider does (synthetic).
public protocol DividendCalendarProvider: DataProvider {
    func upcomingDividends(_ symbol: ProviderSymbol, range: DateRange) async throws -> [DividendEvent]
}

public protocol EarningsCalendarProvider: DataProvider {
    func earnings(range: DateRange) async throws -> [EarningsEvent]
}
