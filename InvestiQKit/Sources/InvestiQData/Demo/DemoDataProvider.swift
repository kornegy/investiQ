import Foundation
import InvestiQCore

/// Serves the synthetic demo universe through the regular provider protocols, so demo mode exercises
/// the same code paths as real data. Every value is labelled `.synthetic` with source "demo".
/// Never registered for real profiles (ADR-008).
public struct DemoDataProvider: MarketDataProvider, FundamentalsProvider, ExchangeRateProvider, BondDataProvider,
                                ETFDataProvider, MacroeconomicDataProvider {
    public static let id = DataSourceInfo.demo.id

    public let info = ProviderInfo(
        id: id, name: DataSourceInfo.demo.name,
        capabilities: [.search, .quotes, .history, .fundamentals, .exchangeRates, .bonds, .etfs, .macro],
        limits: ProviderLimits(requestsPerMinute: 10_000),
        requiresAPIKey: false, quoteDelay: .synthetic, termsURL: nil, signupURL: nil, coverageKey: "provider.coverage.demo")

    private let clock: any TimeProvider

    public init(clock: any TimeProvider) { self.clock = clock }

    private func metadata(currency: CurrencyCode?, marketDate: LocalDate?) -> DataMetadata {
        DataMetadata(source: .demo, retrievedAt: clock.now(), marketTimestamp: marketDate?.startOfDay(in: .current),
                     currency: currency, delay: .synthetic, quality: .validated)
    }

    public static func symbol(for demo: DemoInstrument) -> ProviderSymbol {
        ProviderSymbol(providerID: id, symbol: demo.listing.ticker.rawValue, listing: demo.listing.key, currency: demo.listing.tradingCurrency)
    }

    public func search(_ query: String) async throws -> [InstrumentSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return DemoUniverse.all.filter { demo in
            needle.isEmpty || demo.instrument.name.lowercased().contains(needle)
                || demo.listing.ticker.rawValue.lowercased().contains(needle)
                || demo.instrument.isin?.rawValue.lowercased() == needle
        }.map { demo in
            InstrumentSearchResult(providerID: info.id, symbol: demo.listing.ticker.rawValue, name: demo.instrument.name,
                                   kind: demo.instrument.kind, isin: demo.instrument.isin, mic: demo.listing.mic,
                                   ticker: demo.listing.ticker, currency: demo.listing.tradingCurrency,
                                   country: demo.instrument.country, sector: demo.instrument.sector)
        }
    }

    private func demo(_ symbol: ProviderSymbol) throws -> DemoInstrument {
        guard let demo = DemoUniverse.instrument(listing: symbol.listing) ?? DemoUniverse.instrument(symbol: symbol.symbol) else {
            throw ProviderFailure.notFound
        }
        return demo
    }

    public func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        let demo = try demo(symbol)
        let bars = DemoUniverse.history(for: demo, through: clock.today())
        guard let last = bars.last else { throw ProviderFailure.notFound }
        let previous = bars.dropLast().last?.close
        let change = previous.map { last.close - $0 }
        let quote = Quote(listing: demo.listing.key, price: last.close, currency: demo.listing.tradingCurrency, previousClose: previous,
                          change: change, changePercent: change.flatMap { c in previous.map { c / $0 * 100 } },
                          dayHigh: last.high, dayLow: last.low, volume: last.volume)
        return Sourced(quote, metadata: metadata(currency: demo.listing.tradingCurrency, marketDate: last.date))
    }

    public func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        let demo = try demo(symbol)
        let bars = DemoUniverse.history(for: demo, through: min(range.end, clock.today())).filter { $0.date >= range.start }
        let series = PriceSeries(listing: demo.listing.key, currency: demo.listing.tradingCurrency, adjustment: .split, bars: bars)
        return Sourced(series, metadata: metadata(currency: demo.listing.tradingCurrency, marketDate: series.lastDate))
    }

    public func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot> {
        let demo = try demo(symbol)
        guard let fundamentals = demo.fundamentals else { throw ProviderFailure.notSupported }
        return Sourced(fundamentals, metadata: metadata(currency: fundamentals.currency, marketDate: clock.today()))
    }

    public func rates(base: CurrencyCode, quotes: [CurrencyCode], on date: LocalDate) async throws -> Sourced<[ExchangeRate]> {
        let day = date.isWeekend ? date.previousWeekday : date
        guard let basePerEuro = DemoUniverse.euroRate(base, on: day) else { throw ProviderFailure.notFound }
        let rates: [ExchangeRate] = try quotes.filter { $0 != base }.map { quote in
            guard let quotePerEuro = DemoUniverse.euroRate(quote, on: day) else { throw ProviderFailure.notFound }
            return ExchangeRate(base: base, quote: quote, rate: quotePerEuro / basePerEuro, date: day)
        }
        return Sourced(rates, metadata: metadata(currency: nil, marketDate: day))
    }

    public func bondDetails(isin: ISIN) async throws -> Sourced<BondDetails> {
        guard let demo = DemoUniverse.all.first(where: { $0.instrument.isin == isin }), let bond = demo.bond else {
            throw ProviderFailure.notFound
        }
        return Sourced(bond, metadata: metadata(currency: demo.instrument.currency, marketDate: nil))
    }

    public func bondQuote(isin: ISIN) async throws -> Sourced<Quote> {
        guard let demo = DemoUniverse.all.first(where: { $0.instrument.isin == isin }), demo.bond != nil else {
            throw ProviderFailure.notFound
        }
        return try await quote(Self.symbol(for: demo))
    }

    public func etfDetails(isin: ISIN) async throws -> Sourced<ETFDetails> {
        guard let demo = DemoUniverse.all.first(where: { $0.instrument.isin == isin }), let etf = demo.etf else {
            throw ProviderFailure.notFound
        }
        return Sourced(etf, metadata: metadata(currency: demo.instrument.currency, marketDate: etf.asOf))
    }

    /// Synthetic monthly macro series ("DEMO_CPI_YOY", "DEMO_POLICY_RATE").
    public func series(id: String, range: DateRange) async throws -> Sourced<[MacroObservation]> {
        guard id.hasPrefix("DEMO_") else { throw ProviderFailure.notFound }
        var observations: [MacroObservation] = []
        var date = LocalDate(year: range.start.year, month: range.start.month, day: 1)!
        while date <= range.end {
            let t = Double(date.daysSinceEpoch) / 365.25
            let value = id == "DEMO_POLICY_RATE" ? max(0, 2.5 + 2.0 * sin(t / 3)) : 2.2 + 2.5 * sin(t / 2.5) + 0.3 * cos(t * 3)
            observations.append(MacroObservation(date: date, value: (value * 100).rounded() / 100))
            date = date.adding(months: 1)
        }
        return Sourced(observations, metadata: metadata(currency: nil, marketDate: observations.last?.date))
    }
}
