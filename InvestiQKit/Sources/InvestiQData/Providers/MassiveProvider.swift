import Foundation
import InvestiQCore

/// Massive (formerly Polygon.io). Free "Stocks Basic": 5 calls/min, end-of-day, 2 years history, US only.
/// `api.massive.com` and `api.polygon.io` accept the same keys. Key sent as a Bearer token.
public struct MassiveProvider: MarketDataProvider {
    public static let id = "massive"
    static let base = "https://api.massive.com"

    public let info = ProviderInfo(
        id: id, name: "Massive (formerly Polygon.io)",
        capabilities: [.search, .quotes, .history],
        limits: ProviderLimits(requestsPerMinute: 5),
        requiresAPIKey: true, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://massive.com/terms"),
        signupURL: URL(string: "https://massive.com/pricing"),
        coverageKey: "provider.coverage.massive")

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
        let request = HTTPRequest(url: try URLComponents.make(Self.base, path: path, query: query),
                                  headers: ["Authorization": "Bearer \(key)"])
        let data = try await gateway.fetch(request, provider: info)
        try JSON.rejectNonJSON(data)
        return data
    }

    struct AggregatesDTO: Decodable {
        struct Bar: Decodable { let o: Double?, h: Double?, l: Double?, c: Double?, v: Double?, t: Double? }
        let status: String?
        let results: [Bar]?
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        struct Response: Decodable {
            struct Item: Decodable {
                let ticker: String, name: String?, primary_exchange: String?, type: String?, currency_name: String?, locale: String?
            }
            let results: [Item]?
        }
        let data = try await call("/v3/reference/tickers", ["search": query, "active": "true", "market": "stocks", "limit": "20"])
        return (try JSON.decode(Response.self, from: data).results ?? []).compactMap { item in
            guard let name = item.name else { return nil }
            let kind: InstrumentKind? = switch item.type {
            case "CS": .stock
            case "ETF": .etf
            default: nil
            }
            return InstrumentSearchResult(providerID: info.id, symbol: item.ticker, name: name, kind: kind,
                                          mic: item.primary_exchange.flatMap(MIC.init(rawValue:)), ticker: Ticker(rawValue: item.ticker),
                                          currency: item.currency_name.flatMap { CurrencyCode(rawValue: $0) },
                                          country: item.locale?.uppercased())
        }
    }

    static func bars(_ dto: AggregatesDTO) -> [PriceBar] {
        (dto.results ?? []).compactMap { bar in
            guard let time = bar.t, let close = bar.c.flatMap(Decimal.init(finite:)) else { return nil }
            // Aggregate timestamps are the start of the session window in UTC milliseconds.
            let date = LocalDate(Date(timeIntervalSince1970: time / 1000), timeZone: TimeZone(identifier: "America/New_York") ?? .current)
            return PriceBar(date: date, open: bar.o.flatMap(Decimal.init(finite:)), high: bar.h.flatMap(Decimal.init(finite:)),
                            low: bar.l.flatMap(Decimal.init(finite:)), close: close, volume: bar.v.flatMap(Decimal.init(finite:)))
        }
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        let currency = symbol.currency ?? .usd // Massive Stocks covers US listings only, quoted in USD.
        let dto = try JSON.decode(AggregatesDTO.self, from: try await call("/v2/aggs/ticker/\(symbol.symbol)/prev", ["adjusted": "true"]))
        guard let bar = Self.bars(dto).last else { throw ProviderFailure.notFound }
        let quote = Quote(listing: symbol.listing, price: bar.close, currency: currency, dayHigh: bar.high, dayLow: bar.low, volume: bar.volume)
        let marketTime = bar.date.startOfDay(in: TimeZone(identifier: "America/New_York") ?? .current)
        try DataValidator.validate(quote, marketTimestamp: marketTime, now: clock.now())
        return Sourced(quote, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: marketTime,
                                                     currency: currency, delay: .endOfDay, quality: .validated))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        let currency = symbol.currency ?? .usd
        let path = "/v2/aggs/ticker/\(symbol.symbol)/range/1/day/\(range.start.iso)/\(range.end.iso)"
        let dto = try JSON.decode(AggregatesDTO.self, from: try await call(path, ["adjusted": "true", "sort": "asc", "limit": "50000"]))
        let series = PriceSeries(listing: symbol.listing, currency: currency, adjustment: .split, bars: Self.bars(dto))
        let (cleaned, dropped) = DataValidator.clean(series, today: clock.today())
        return Sourced(cleaned, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                       marketTimestamp: cleaned.lastDate?.startOfDay(in: .current), currency: currency,
                                                       delay: .endOfDay, quality: dropped > 0 ? .partial : .validated))
    }
}
