import Foundation
import InvestiQCore

/// Financial Modeling Prep (`stable` API). Free plan: 250 calls/day, end-of-day, personal licence.
/// Used for ISIN search, profiles and quotes. FMP requires the key as a query parameter; it is
/// redacted from every log/cache key (docs/SECURITY.md §5).
public struct FinancialModelingPrepProvider: MarketDataProvider, FundamentalsProvider {
    public static let id = "fmp"
    static let base = "https://financialmodelingprep.com/stable"

    public let info = ProviderInfo(
        id: id, name: "Financial Modeling Prep",
        capabilities: [.search, .quotes, .fundamentals],
        limits: ProviderLimits(requestsPerMinute: 10, requestsPerDay: 250),
        requiresAPIKey: true, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://site.financialmodelingprep.com/terms-of-service"),
        signupURL: URL(string: "https://site.financialmodelingprep.com/developer/docs"),
        coverageKey: "provider.coverage.fmp")

    private let gateway: ProviderGateway
    private let credentials: any CredentialSource
    private let clock: any TimeProvider

    public init(gateway: ProviderGateway, credentials: any CredentialSource, clock: any TimeProvider) {
        self.gateway = gateway
        self.credentials = credentials
        self.clock = clock
    }

    private func call(_ path: String, _ query: [String: String?]) async throws -> Data {
        guard let key = credentials.apiKey(for: info.id) else { throw ProviderFailure.missingAPIKey }
        var parameters = query
        parameters["apikey"] = key
        let data = try await gateway.fetch(HTTPRequest(url: try URLComponents.make(Self.base, path: path, query: parameters)), provider: info)
        try JSON.rejectNonJSON(data)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["Error Message"] as? String {
            throw message.lowercased().contains("api key") ? ProviderFailure.unauthorized : ProviderFailure.notSupported
        }
        return data
    }

    struct SearchItem: Decodable {
        let symbol: String, name: String?, currency: String?, exchange: String?, exchangeFullName: String?, isin: String?
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let items: [SearchItem]
        if let isin = ISIN(rawValue: trimmed) {
            items = try JSON.decode([SearchItem].self, from: try await call("/search-isin", ["isin": isin.rawValue]))
        } else {
            items = try JSON.decode([SearchItem].self, from: try await call("/search-name", ["query": trimmed, "limit": "30"]))
        }
        return items.compactMap { item in
            guard let name = item.name else { return nil }
            return InstrumentSearchResult(providerID: info.id, symbol: item.symbol, name: name, kind: nil,
                                          isin: item.isin.flatMap(ISIN.init(rawValue:)),
                                          exchangeName: item.exchangeFullName ?? item.exchange, ticker: Ticker(rawValue: item.symbol),
                                          currency: item.currency.flatMap(CurrencyCode.init(rawValue:)))
        }
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        struct QuoteDTO: Decodable {
            let price, change, changePercentage, previousClose, dayHigh, dayLow, volume: LenientDecimal?
            let timestamp: Double?
        }
        guard let currency = symbol.currency else { throw ProviderFailure.misconfigured("currency unknown for \(symbol.symbol)") }
        let items = try JSON.decode([QuoteDTO].self, from: try await call("/quote", ["symbol": symbol.symbol]))
        guard let dto = items.first, let price = dto.price?.value else { throw ProviderFailure.notFound }
        let quote = Quote(listing: symbol.listing, price: price, currency: currency, previousClose: dto.previousClose?.value,
                          change: dto.change?.value, changePercent: dto.changePercentage?.value, dayHigh: dto.dayHigh?.value,
                          dayLow: dto.dayLow?.value, volume: dto.volume?.value)
        let marketTime = dto.timestamp.map { Date(timeIntervalSince1970: $0) }
        try DataValidator.validate(quote, marketTimestamp: marketTime, now: clock.now())
        return Sourced(quote, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: marketTime,
                                                     currency: currency, delay: info.quoteDelay, quality: .validated))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        // The adjustment basis of FMP's EOD endpoint has not been verified against live data, so this
        // adapter does not supply history (docs/DATA_PROVIDERS.md, honest limitation).
        throw ProviderFailure.notSupported
    }

    public func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot> {
        struct ProfileDTO: Decodable {
            let companyName: String?, currency: String?, isin: String?, sector: String?, industry: String?,
                country: String?, description: String?, marketCap: LenientDecimal?, beta: LenientDecimal?,
                lastDividend: LenientDecimal?
        }
        let items = try JSON.decode([ProfileDTO].self, from: try await call("/profile", ["symbol": symbol.symbol]))
        guard let profile = items.first, profile.companyName != nil else { throw ProviderFailure.notFound }
        let currency = profile.currency.flatMap(CurrencyCode.init(rawValue:))
        let snapshot = FundamentalsSnapshot(currency: currency, businessDescription: profile.description, sector: profile.sector,
                                            industry: profile.industry, country: profile.country,
                                            marketCapitalization: profile.marketCap?.value, beta: profile.beta?.value)
        return Sourced(snapshot, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), currency: currency,
                                                        delay: .endOfDay, quality: .unvalidated))
    }
}
