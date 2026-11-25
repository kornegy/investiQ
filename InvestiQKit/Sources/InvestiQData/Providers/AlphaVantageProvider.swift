import Foundation
import InvestiQCore

/// Alpha Vantage adapter (docs/DATA_PROVIDERS.md §2–3). Free keys: ~25 requests/day, compact history.
/// Errors and rate limits arrive as HTTP 200 with `Information`/`Note`/`Error Message` keys.
public struct AlphaVantageProvider: MarketDataProvider, FundamentalsProvider {
    public static let id = "alphavantage"
    static let base = "https://www.alphavantage.co/query"

    public let info = ProviderInfo(
        id: id, name: "Alpha Vantage",
        capabilities: [.search, .quotes, .history, .fundamentals],
        limits: ProviderLimits(requestsPerMinute: 5, requestsPerDay: 25),
        requiresAPIKey: true, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://www.alphavantage.co/terms_of_service/"),
        signupURL: URL(string: "https://www.alphavantage.co/support/#api-key"),
        coverageKey: "provider.coverage.alphavantage")

    private let gateway: ProviderGateway
    private let credentials: any CredentialSource
    private let clock: any TimeProvider

    public init(gateway: ProviderGateway, credentials: any CredentialSource, clock: any TimeProvider) {
        self.gateway = gateway
        self.credentials = credentials
        self.clock = clock
    }

    private func call(_ parameters: [String: String]) async throws -> Data {
        guard let key = credentials.apiKey(for: info.id) else { throw ProviderFailure.missingAPIKey }
        var query: [String: String?] = parameters
        query["apikey"] = key
        let data = try await gateway.fetch(HTTPRequest(url: try URLComponents.make(Self.base, query: query)), provider: info)
        try JSON.rejectNonJSON(data)
        try Self.checkEnvelope(data)
        return data
    }

    /// Alpha Vantage reports errors in the body with HTTP 200.
    static func checkEnvelope(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let message = (object["Information"] ?? object["Note"]) as? String {
            let lowered = message.lowercased()
            if lowered.contains("premium") { throw ProviderFailure.notSupported }
            if lowered.contains("api key") && lowered.contains("invalid") { throw ProviderFailure.unauthorized }
            throw ProviderFailure.rateLimited(retryAfter: nil)
        }
        if let message = object["Error Message"] as? String {
            throw message.lowercased().contains("apikey") ? ProviderFailure.unauthorized : ProviderFailure.notFound
        }
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        let data = try await call(["function": "SYMBOL_SEARCH", "keywords": query])
        struct Response: Decodable { let bestMatches: [[String: String]]? }
        return (try JSON.decode(Response.self, from: data).bestMatches ?? []).compactMap { match in
            guard let symbol = match["1. symbol"], let name = match["2. name"] else { return nil }
            let (ticker, mic) = Self.splitSymbol(symbol)
            return InstrumentSearchResult(
                providerID: info.id, symbol: symbol, name: name, kind: Self.kind(match["3. type"]),
                mic: mic, exchangeName: match["4. region"], ticker: ticker,
                currency: match["8. currency"].flatMap(CurrencyCode.init(rawValue:)))
        }
    }

    /// Maps Alpha Vantage exchange suffixes to ISO 10383 MICs where unambiguous.
    static func splitSymbol(_ symbol: String) -> (Ticker?, MIC?) {
        let suffixes = ["LON": "XLON", "DEX": "XETR", "FRK": "XFRA", "AMS": "XAMS", "PAR": "XPAR"]
        let parts = symbol.split(separator: ".")
        if parts.count == 2, let mic = suffixes[String(parts[1])] {
            return (Ticker(rawValue: String(parts[0])), MIC(rawValue: mic))
        }
        return (Ticker(rawValue: symbol), nil)
    }

    static func kind(_ type: String?) -> InstrumentKind? {
        switch type?.lowercased() {
        case "equity": return .stock
        case "etf": return .etf
        default: return nil
        }
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        guard let currency = symbol.currency else { throw ProviderFailure.misconfigured("currency unknown for \(symbol.symbol)") }
        let data = try await call(["function": "GLOBAL_QUOTE", "symbol": symbol.symbol])
        let decoder = try JSON.decode(GlobalQuoteEnvelope.self, from: data)
        guard let q = decoder.quote, let price = q.price else { throw ProviderFailure.notFound }
        let quote = Quote(listing: symbol.listing, price: price, currency: currency, previousClose: q.previousClose,
                          change: q.change, changePercent: q.changePercent, dayHigh: q.high, dayLow: q.low, volume: q.volume)
        let marketTime = q.latestTradingDay?.startOfDay(in: TimeZone(identifier: "America/New_York") ?? .current)
        try DataValidator.validate(quote, marketTimestamp: marketTime, now: clock.now())
        return Sourced(quote, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: marketTime,
                                                     currency: currency, delay: info.quoteDelay, quality: .validated))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        guard let currency = symbol.currency else { throw ProviderFailure.misconfigured("currency unknown for \(symbol.symbol)") }
        // `compact` (≈100 sessions) is what free keys receive; full history is a premium feature.
        let data = try await call(["function": "TIME_SERIES_DAILY", "symbol": symbol.symbol, "outputsize": "compact"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let series = root["Time Series (Daily)"] as? [String: [String: String]] else {
            throw ProviderFailure.invalidResponse("missing time series")
        }
        let bars: [PriceBar] = series.compactMap { dateText, values in
            guard let date = LocalDate(iso: dateText), date >= range.start, date <= range.end,
                  let close = values["4. close"].flatMap(DecimalSupport.parse) else { return nil }
            return PriceBar(date: date, open: values["1. open"].flatMap(DecimalSupport.parse),
                            high: values["2. high"].flatMap(DecimalSupport.parse), low: values["3. low"].flatMap(DecimalSupport.parse),
                            close: close, volume: values["5. volume"].flatMap(DecimalSupport.parse))
        }
        // TIME_SERIES_DAILY returns raw (as-traded) prices.
        let raw = PriceSeries(listing: symbol.listing, currency: currency, adjustment: .unadjusted, bars: bars)
        let (cleaned, dropped) = DataValidator.clean(raw, today: clock.today())
        return Sourced(cleaned, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                       marketTimestamp: cleaned.lastDate?.startOfDay(in: .current),
                                                       currency: currency, delay: .endOfDay, quality: dropped > 0 ? .partial : .validated))
    }

    public func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot> {
        let data = try await call(["function": "OVERVIEW", "symbol": symbol.symbol])
        let overview = try JSON.decode(OverviewDTO.self, from: data)
        guard overview.symbol != nil else { throw ProviderFailure.notFound }
        let snapshot = FundamentalsSnapshot(
            currency: overview.currency, asOf: overview.latestQuarter, businessDescription: overview.description,
            sector: overview.sector, industry: overview.industry, country: overview.country,
            marketCapitalization: overview.marketCap, sharesOutstanding: overview.shares, revenueTTM: overview.revenue,
            revenueGrowthYoY: overview.revenueGrowth, epsTTM: overview.eps, peRatio: overview.pe, pbRatio: overview.pb,
            operatingMargin: overview.operatingMargin, profitMargin: overview.profitMargin,
            dividendYield: overview.dividendYield, dividendPerShare: overview.dividendPerShare, beta: overview.beta,
            bookValuePerShare: overview.bookValue)
        return Sourced(snapshot, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), currency: overview.currency,
                                                        delay: .endOfDay, quality: .unvalidated))
    }
}

struct GlobalQuoteEnvelope: Decodable {
    struct Fields: Decodable {
        let price, previousClose, change, changePercent, high, low, volume: Decimal?
        let latestTradingDay: LocalDate?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            price = c.lenientDecimal(AnyKey("05. price"))
            previousClose = c.lenientDecimal(AnyKey("08. previous close"))
            change = c.lenientDecimal(AnyKey("09. change"))
            changePercent = c.lenientDecimal(AnyKey("10. change percent"))
            high = c.lenientDecimal(AnyKey("03. high"))
            low = c.lenientDecimal(AnyKey("04. low"))
            volume = c.lenientDecimal(AnyKey("06. volume"))
            latestTradingDay = c.lenientString(AnyKey("07. latest trading day")).flatMap(LocalDate.init(iso:))
        }
    }

    let quote: Fields?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        // An unknown symbol yields `"Global Quote": {}`.
        let fields = try c.decodeIfPresent(Fields.self, forKey: AnyKey("Global Quote"))
        quote = fields?.price == nil ? nil : fields
    }
}

struct OverviewDTO: Decodable {
    let symbol, description, sector, industry, country: String?
    let currency: CurrencyCode?
    let latestQuarter: LocalDate?
    let marketCap, shares, revenue, revenueGrowth, eps, pe, pb, operatingMargin, profitMargin, dividendYield,
        dividendPerShare, beta, bookValue: Decimal?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        symbol = c.lenientString(AnyKey("Symbol"))
        description = c.lenientString(AnyKey("Description"))
        sector = c.lenientString(AnyKey("Sector"))
        industry = c.lenientString(AnyKey("Industry"))
        country = c.lenientString(AnyKey("Country"))
        currency = c.lenientString(AnyKey("Currency")).flatMap(CurrencyCode.init(rawValue:))
        latestQuarter = c.lenientString(AnyKey("LatestQuarter")).flatMap(LocalDate.init(iso:))
        marketCap = c.lenientDecimal(AnyKey("MarketCapitalization"))
        shares = c.lenientDecimal(AnyKey("SharesOutstanding"))
        revenue = c.lenientDecimal(AnyKey("RevenueTTM"))
        revenueGrowth = c.lenientDecimal(AnyKey("QuarterlyRevenueGrowthYOY"))
        eps = c.lenientDecimal(AnyKey("EPS"))
        pe = c.lenientDecimal(AnyKey("PERatio"))
        pb = c.lenientDecimal(AnyKey("PriceToBookRatio"))
        operatingMargin = c.lenientDecimal(AnyKey("OperatingMarginTTM"))
        profitMargin = c.lenientDecimal(AnyKey("ProfitMargin"))
        dividendYield = c.lenientDecimal(AnyKey("DividendYield"))
        dividendPerShare = c.lenientDecimal(AnyKey("DividendPerShare"))
        beta = c.lenientDecimal(AnyKey("Beta"))
        bookValue = c.lenientDecimal(AnyKey("BookValue"))
    }
}
