import Foundation
import InvestiQCore

/// Twelve Data adapter. Basic plan: 8 credits/min, 800/day, US + forex; EU exchanges need paid plans.
/// Errors arrive as `{"status":"error","code":…}` (often with HTTP 200). Key sent in a header.
public struct TwelveDataProvider: MarketDataProvider {
    public static let id = "twelvedata"
    static let base = "https://api.twelvedata.com"

    public let info = ProviderInfo(
        id: id, name: "Twelve Data",
        capabilities: [.search, .quotes, .history],
        limits: ProviderLimits(requestsPerMinute: 8, requestsPerDay: 800),
        requiresAPIKey: true, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://twelvedata.com/terms"),
        signupURL: URL(string: "https://twelvedata.com/pricing"),
        coverageKey: "provider.coverage.twelvedata")

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
                                  headers: ["Authorization": "apikey \(key)"])
        let data = try await gateway.fetch(request, provider: info)
        try JSON.rejectNonJSON(data)
        try Self.checkStatus(data)
        return data
    }

    static func checkStatus(_ data: Data) throws {
        struct Envelope: Decodable { let status: String?; let code: Int?; let message: String? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.status == "error" else { return }
        switch envelope.code {
        case 401: throw ProviderFailure.unauthorized
        case 403: throw ProviderFailure.notSupported
        case 404, 400: throw ProviderFailure.notFound
        case 429: throw ProviderFailure.rateLimited(retryAfter: nil)
        default: throw ProviderFailure.invalidResponse(envelope.message ?? "error status")
        }
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        struct Response: Decodable {
            struct Item: Decodable {
                let symbol: String, instrument_name: String?, exchange: String?, mic_code: String?,
                    instrument_type: String?, country: String?, currency: String?
            }
            let data: [Item]?
        }
        let response = try JSON.decode(Response.self, from: try await call("/symbol_search", ["symbol": query, "outputsize": "30"]))
        return (response.data ?? []).compactMap { item in
            guard let name = item.instrument_name else { return nil }
            let kind: InstrumentKind? = switch item.instrument_type?.lowercased() {
            case "common stock": .stock
            case "etf": .etf
            default: nil
            }
            return InstrumentSearchResult(providerID: info.id, symbol: item.symbol, name: name, kind: kind,
                                          mic: item.mic_code.flatMap(MIC.init(rawValue:)), exchangeName: item.exchange,
                                          ticker: Ticker(rawValue: item.symbol),
                                          currency: item.currency.flatMap(CurrencyCode.init(rawValue:)), country: item.country)
        }
    }

    private func symbolQuery(_ symbol: ProviderSymbol) -> [String: String?] {
        ["symbol": symbol.symbol, "mic_code": symbol.listing.mic?.rawValue]
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        struct QuoteDTO: Decodable {
            let currency: String?, timestamp: Double?, close, previous_close, change, percent_change, high, low, volume: LenientDecimal?
        }
        let dto = try JSON.decode(QuoteDTO.self, from: try await call("/quote", symbolQuery(symbol)))
        guard let price = dto.close?.value,
              let currency = dto.currency.flatMap(CurrencyCode.init(rawValue:)) ?? symbol.currency else {
            throw ProviderFailure.invalidResponse("missing price or currency")
        }
        let quote = Quote(listing: symbol.listing, price: price, currency: currency, previousClose: dto.previous_close?.value,
                          change: dto.change?.value, changePercent: dto.percent_change?.value, dayHigh: dto.high?.value,
                          dayLow: dto.low?.value, volume: dto.volume?.value)
        let marketTime = dto.timestamp.map { Date(timeIntervalSince1970: $0) }
        try DataValidator.validate(quote, marketTimestamp: marketTime, now: clock.now())
        return Sourced(quote, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: marketTime,
                                                     currency: currency, delay: info.quoteDelay, quality: .validated))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        struct Response: Decodable {
            struct Meta: Decodable { let currency: String? }
            struct Value: Decodable { let datetime: String; let open, high, low, close, volume: LenientDecimal? }
            let meta: Meta?
            let values: [Value]?
        }
        var query = symbolQuery(symbol)
        query["interval"] = "1day"
        query["start_date"] = range.start.iso
        query["end_date"] = range.end.iso
        query["adjust"] = "splits" // request split-adjusted prices explicitly
        query["outputsize"] = "5000"
        let response = try JSON.decode(Response.self, from: try await call("/time_series", query))
        guard let currency = response.meta?.currency.flatMap(CurrencyCode.init(rawValue:)) ?? symbol.currency else {
            throw ProviderFailure.invalidResponse("missing currency")
        }
        let bars: [PriceBar] = (response.values ?? []).compactMap { value in
            guard let date = LocalDate(iso: value.datetime), let close = value.close?.value else { return nil }
            return PriceBar(date: date, open: value.open?.value, high: value.high?.value, low: value.low?.value,
                            close: close, volume: value.volume?.value)
        }
        let (cleaned, dropped) = DataValidator.clean(PriceSeries(listing: symbol.listing, currency: currency, adjustment: .split, bars: bars),
                                                     today: clock.today())
        return Sourced(cleaned, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                       marketTimestamp: cleaned.lastDate?.startOfDay(in: .current), currency: currency,
                                                       delay: .endOfDay, quality: dropped > 0 ? .partial : .validated))
    }
}
