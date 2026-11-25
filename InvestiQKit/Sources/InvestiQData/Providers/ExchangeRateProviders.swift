import Foundation
import InvestiQCore

/// European Central Bank euro reference rates via the ECB Data Portal (SDMX REST, CSV).
/// No key required; published on TARGET working days around 16:00 CET. Rates = units of CCY per 1 EUR.
public struct ECBExchangeRateProvider: ExchangeRateProvider, MacroeconomicDataProvider {
    public static let id = "ecb"
    static let base = "https://data-api.ecb.europa.eu/service/data"

    public let info = ProviderInfo(
        id: id, name: "European Central Bank",
        capabilities: [.exchangeRates, .macro],
        limits: ProviderLimits(requestsPerMinute: 30),
        requiresAPIKey: false, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://www.ecb.europa.eu/services/disclaimer/html/index.en.html"),
        signupURL: nil, coverageKey: "provider.coverage.ecb")

    private let gateway: ProviderGateway
    private let clock: any TimeProvider
    /// Look-back window so weekends/holidays still yield the latest published rate.
    static let lookBackDays = 10

    public init(gateway: ProviderGateway, clock: any TimeProvider) {
        self.gateway = gateway
        self.clock = clock
    }

    public func rates(base: CurrencyCode, quotes: [CurrencyCode], on date: LocalDate) async throws -> Sourced<[ExchangeRate]> {
        let targets = Set(quotes + [base]).filter { $0 != .eur }.sorted()
        guard !targets.isEmpty else {
            return Sourced([], metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), delay: .endOfDay, quality: .validated))
        }
        let key = "EXR/D.\(targets.map(\.rawValue).joined(separator: "+")).EUR.SP00.A"
        let url = try URLComponents.make(Self.base, path: "/" + key, query: [
            "format": "csvdata", "startPeriod": date.adding(days: -Self.lookBackDays).iso, "endPeriod": date.iso])
        let data = try await gateway.fetch(HTTPRequest(url: url), provider: info)
        let perEuro = try Self.parseEuroRates(data, onOrBefore: date)
        // Convert EUR-based rates into the requested base: CCY per BASE = (CCY per EUR) / (BASE per EUR).
        func perEuroRate(_ currency: CurrencyCode) -> (Decimal, LocalDate)? {
            currency == .eur ? (1, date) : perEuro[currency]
        }
        guard let baseRate = perEuroRate(base) else { throw ProviderFailure.notFound }
        let result: [ExchangeRate] = try quotes.filter { $0 != base }.map { quote in
            guard let quoteRate = perEuroRate(quote) else { throw ProviderFailure.notFound }
            return ExchangeRate(base: base, quote: quote, rate: quoteRate.0 / baseRate.0, date: min(quoteRate.1, baseRate.1))
        }
        try DataValidator.validate(result)
        let observed = result.map(\.date).min() ?? date
        return Sourced(result, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                      marketTimestamp: observed.startOfDay(in: TimeZone(identifier: "Europe/Frankfurt") ?? .current),
                                                      delay: .endOfDay, quality: .validated))
    }

    /// Parses ECB `csvdata`: columns are located by header name, never by position.
    static func parseEuroRates(_ data: Data, onOrBefore date: LocalDate) throws -> [CurrencyCode: (Decimal, LocalDate)] {
        let table: CSVTable
        do { table = CSVTable(rows: try CSVParser().parse(data)) } catch { throw ProviderFailure.invalidResponse("CSV") }
        guard table.index(of: "TIME_PERIOD") != nil, table.index(of: "OBS_VALUE") != nil, table.index(of: "CURRENCY") != nil else {
            throw ProviderFailure.invalidResponse("unexpected ECB columns")
        }
        var latest: [CurrencyCode: (Decimal, LocalDate)] = [:]
        for row in table.rows {
            guard table.value(row, "CURRENCY_DENOM") == nil || table.value(row, "CURRENCY_DENOM") == "EUR",
                  let currency = table.value(row, "CURRENCY").flatMap(CurrencyCode.init(rawValue:)),
                  let day = table.value(row, "TIME_PERIOD").flatMap(LocalDate.init(iso:)), day <= date,
                  let value = table.value(row, "OBS_VALUE").flatMap(DecimalSupport.parse), value > 0 else { continue }
            if let existing = latest[currency], existing.1 >= day { continue }
            latest[currency] = (value, day)
        }
        return latest
    }

    /// Macro series from the ECB Data Portal, e.g. `ICP/M.U2.N.000000.4.ANR` (euro-area HICP inflation).
    public func series(id: String, range: DateRange) async throws -> Sourced<[MacroObservation]> {
        guard id.range(of: #"^[A-Z0-9_]+/[A-Za-z0-9_.+]+$"#, options: .regularExpression) != nil else {
            throw ProviderFailure.misconfigured("invalid ECB series key")
        }
        let url = try URLComponents.make(Self.base, path: "/" + id, query: [
            "format": "csvdata", "startPeriod": range.start.iso, "endPeriod": range.end.iso])
        let data = try await gateway.fetch(HTTPRequest(url: url), provider: info)
        let table = CSVTable(rows: (try? CSVParser().parse(data)) ?? [])
        let observations: [MacroObservation] = table.rows.compactMap { row in
            guard let period = table.value(row, "TIME_PERIOD") else { return nil }
            // Monthly periods ("2026-09") are mapped to the first day of the month.
            let date = LocalDate(iso: period) ?? LocalDate(iso: period + "-01")
            return date.map { MacroObservation(date: $0, value: table.value(row, "OBS_VALUE").flatMap(Double.init)) }
        }
        return Sourced(observations.sorted { $0.date < $1.date },
                       metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), delay: .endOfDay, quality: .unvalidated))
    }
}

/// Czech National Bank exchange-rate fixing (`api.cnb.cz/cnbapi/exrates/daily`). No key required.
/// `rate` is CZK per `amount` units of the currency (e.g. 100 JPY), normalised here to per-unit.
public struct CNBExchangeRateProvider: ExchangeRateProvider {
    public static let id = "cnb"
    static let base = "https://api.cnb.cz/cnbapi"

    public let info = ProviderInfo(
        id: id, name: "Czech National Bank",
        capabilities: [.exchangeRates],
        limits: ProviderLimits(requestsPerMinute: 30),
        requiresAPIKey: false, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://www.cnb.cz/en/terms-of-use/"),
        signupURL: nil, coverageKey: "provider.coverage.cnb")

    private let gateway: ProviderGateway
    private let clock: any TimeProvider

    public init(gateway: ProviderGateway, clock: any TimeProvider) {
        self.gateway = gateway
        self.clock = clock
    }

    struct Response: Decodable {
        struct Rate: Decodable {
            let validFor: String?, amount: LenientDecimal?, currencyCode: String?, rate: LenientDecimal?
        }
        let rates: [Rate]?
    }

    /// CZK per one unit of each currency, as published for `date` (or the last working day before it).
    static func parse(_ data: Data) throws -> [CurrencyCode: (Decimal, LocalDate)] {
        try JSON.rejectNonJSON(data)
        let response = try JSON.decode(Response.self, from: data)
        var result: [CurrencyCode: (Decimal, LocalDate)] = [:]
        for item in response.rates ?? [] {
            guard let code = item.currencyCode.flatMap(CurrencyCode.init(rawValue:)),
                  let amount = item.amount?.value, amount > 0, let rate = item.rate?.value, rate > 0,
                  let day = item.validFor.flatMap(LocalDate.init(iso:)) else { continue }
            result[code] = (rate / amount, day)
        }
        guard !result.isEmpty else { throw ProviderFailure.invalidResponse("no CNB rates") }
        return result
    }

    public func rates(base: CurrencyCode, quotes: [CurrencyCode], on date: LocalDate) async throws -> Sourced<[ExchangeRate]> {
        let url = try URLComponents.make(Self.base, path: "/exrates/daily", query: ["date": date.iso, "lang": "EN"])
        let perCZK = try Self.parse(try await gateway.fetch(HTTPRequest(url: url), provider: info))
        func czkPerUnit(_ currency: CurrencyCode) -> (Decimal, LocalDate)? { currency == .czk ? (1, date) : perCZK[currency] }
        guard let baseCZK = czkPerUnit(base) else { throw ProviderFailure.notFound }
        // QUOTE per BASE = (CZK per BASE) / (CZK per QUOTE).
        let result: [ExchangeRate] = try quotes.filter { $0 != base }.map { quote in
            guard let quoteCZK = czkPerUnit(quote) else { throw ProviderFailure.notFound }
            return ExchangeRate(base: base, quote: quote, rate: baseCZK.0 / quoteCZK.0, date: min(baseCZK.1, quoteCZK.1))
        }
        try DataValidator.validate(result)
        return Sourced(result, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                      marketTimestamp: result.first?.date.startOfDay(in: TimeZone(identifier: "Europe/Prague") ?? .current),
                                                      delay: .endOfDay, quality: .validated))
    }
}
