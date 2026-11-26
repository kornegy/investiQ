import Foundation
import InvestiQCore

/// Finnhub adapter. Free plan: 60 calls/min; candles (history) are premium, so `history` is not
/// offered. The API key is sent in the `X-Finnhub-Token` header (never in the URL).
public struct FinnhubProvider: MarketDataProvider, FundamentalsProvider, NewsProvider, EarningsCalendarProvider {
    public static let id = "finnhub"
    static let base = "https://finnhub.io/api/v1"

    public let info = ProviderInfo(
        id: id, name: "Finnhub",
        capabilities: [.search, .quotes, .fundamentals, .news, .earningsCalendar],
        limits: ProviderLimits(requestsPerMinute: 60),
        requiresAPIKey: true, quoteDelay: .delayed(minutes: 15),
        termsURL: URL(string: "https://finnhub.io/terms-of-service"),
        signupURL: URL(string: "https://finnhub.io/register"),
        coverageKey: "provider.coverage.finnhub")

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
                                  headers: ["X-Finnhub-Token": key])
        let data = try await gateway.fetch(request, provider: info)
        try JSON.rejectNonJSON(data)
        return data
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        struct Response: Decodable {
            struct Item: Decodable { let description: String?; let displaySymbol: String?; let symbol: String; let type: String? }
            let result: [Item]?
        }
        let data = try await call("/search", ["q": query])
        return (try JSON.decode(Response.self, from: data).result ?? []).compactMap { item in
            guard let name = item.description, !name.isEmpty else { return nil }
            let kind: InstrumentKind? = switch item.type?.lowercased() {
            case "common stock": .stock
            case "etp", "etf": .etf
            default: nil
            }
            return InstrumentSearchResult(providerID: info.id, symbol: item.symbol, name: name, kind: kind,
                                          ticker: Ticker(rawValue: item.displaySymbol ?? item.symbol))
        }
    }

    struct QuoteDTO: Decodable {
        let c: Double?, d: Double?, dp: Double?, h: Double?, l: Double?, o: Double?, pc: Double?, t: Double?
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        guard let currency = symbol.currency else { throw ProviderFailure.misconfigured("currency unknown for \(symbol.symbol)") }
        let dto = try JSON.decode(QuoteDTO.self, from: try await call("/quote", ["symbol": symbol.symbol]))
        // Unknown symbols return an all-zero quote — that is "not found", never a zero price.
        guard let price = dto.c, price > 0, let time = dto.t, time > 0 else { throw ProviderFailure.notFound }
        func decimal(_ value: Double?) -> Decimal? { value.flatMap(Decimal.init(finite:)) }
        let quote = Quote(listing: symbol.listing, price: decimal(price) ?? 0, currency: currency,
                          previousClose: decimal(dto.pc), change: decimal(dto.d), changePercent: decimal(dto.dp),
                          dayHigh: decimal(dto.h), dayLow: decimal(dto.l))
        let marketTime = Date(timeIntervalSince1970: time)
        try DataValidator.validate(quote, marketTimestamp: marketTime, now: clock.now())
        return Sourced(quote, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: marketTime,
                                                     currency: currency, delay: info.quoteDelay, quality: .validated))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        // Stock candles are a premium Finnhub feature; do not spend quota on a request that returns 403.
        throw ProviderFailure.notSupported
    }

    public func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot> {
        struct Profile: Decodable {
            let country: String?, currency: String?, finnhubIndustry: String?, marketCapitalization: Double?,
                shareOutstanding: Double?, name: String?
        }
        struct Metrics: Decodable { let metric: [String: LenientDecimal]? }
        let profile = try JSON.decode(Profile.self, from: try await call("/stock/profile2", ["symbol": symbol.symbol]))
        guard profile.name != nil else { throw ProviderFailure.notFound }
        let metrics = try JSON.decode(Metrics.self, from: try await call("/stock/metric", ["symbol": symbol.symbol, "metric": "all"]))
        func metric(_ key: String) -> Decimal? { metrics.metric?[key]?.value }
        // Finnhub reports market cap and shares in millions; ratios in percent for margins/yields.
        let million: Decimal = 1_000_000
        let snapshot = FundamentalsSnapshot(
            currency: profile.currency.flatMap(CurrencyCode.init(rawValue:)), sector: profile.finnhubIndustry,
            country: profile.country,
            marketCapitalization: profile.marketCapitalization.flatMap(Decimal.init(finite:)).map { $0 * million },
            sharesOutstanding: profile.shareOutstanding.flatMap(Decimal.init(finite:)).map { $0 * million },
            revenueGrowthYoY: metric("revenueGrowthTTMYoy").map { $0 / 100 },
            epsTTM: metric("epsTTM") ?? metric("epsBasicExclExtraItemsTTM"),
            peRatio: metric("peTTM") ?? metric("peBasicExclExtraTTM"), pbRatio: metric("pbAnnual"),
            debtToEquity: metric("totalDebt/totalEquityAnnual"),
            operatingMargin: metric("operatingMarginTTM").map { $0 / 100 },
            profitMargin: metric("netProfitMarginTTM").map { $0 / 100 },
            dividendYield: metric("dividendYieldIndicatedAnnual").map { $0 / 100 },
            beta: metric("beta"), bookValuePerShare: metric("bookValuePerShareAnnual"))
        return Sourced(snapshot, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                        currency: snapshot.currency, delay: .endOfDay, quality: .unvalidated))
    }

    struct NewsDTO: Decodable {
        let category: String?, datetime: Double?, headline: String?, related: String?, source: String?,
            summary: String?, url: String?
    }

    public func latestNews(symbols: [String], limit: Int) async throws -> [RawNewsItem] {
        let today = clock.today(in: TimeZone(identifier: "UTC") ?? .current)
        var items: [NewsDTO] = []
        if symbols.isEmpty {
            items = try JSON.decode([NewsDTO].self, from: try await call("/news", ["category": "general"]))
        } else {
            for symbol in symbols.prefix(5) {
                items += try JSON.decode([NewsDTO].self, from: try await call("/company-news", [
                    "symbol": symbol, "from": today.adding(days: -7).iso, "to": today.iso]))
            }
        }
        return items.compactMap { dto -> RawNewsItem? in
            guard let headline = dto.headline, !headline.isEmpty, let link = dto.url, let url = URL(string: link),
                  url.scheme == "https", let time = dto.datetime, time > 0 else { return nil }
            return RawNewsItem(providerID: info.id, headline: headline, summary: dto.summary, url: url,
                               sourceName: dto.source ?? info.name, publishedAt: Date(timeIntervalSince1970: time),
                               relatedSymbols: (dto.related ?? "").split(separator: ",").map { String($0) }.filter { !$0.isEmpty },
                               providerCategory: dto.category, language: "en")
        }
        .sorted { $0.publishedAt > $1.publishedAt }
        .prefix(limit).map { $0 }
    }

    public func earnings(range: DateRange) async throws -> [EarningsEvent] {
        struct Response: Decodable {
            struct Item: Decodable {
                let date: String?, epsActual: LenientDecimal?, epsEstimate: LenientDecimal?, hour: String?, symbol: String?
            }
            let earningsCalendar: [Item]?
        }
        let data = try await call("/calendar/earnings", ["from": range.start.iso, "to": range.end.iso])
        return (try JSON.decode(Response.self, from: data).earningsCalendar ?? []).compactMap { item in
            guard let symbol = item.symbol, let date = item.date.flatMap(LocalDate.init(iso:)) else { return nil }
            return EarningsEvent(symbol: symbol, date: date, hour: item.hour, epsEstimate: item.epsEstimate?.value,
                                 epsActual: item.epsActual?.value)
        }
    }
}
