import XCTest
@testable import InvestiQServices
import InvestiQCore
import InvestiQData
import InvestiQPersistence
import InvestiQTestSupport

/// Scriptable provider for service tests.
final class ScriptedProvider: MarketDataProvider, @unchecked Sendable {
    let info: ProviderInfo
    var quoteResult: Result<Decimal, ProviderFailure>
    var calls = 0
    let clock: any TimeProvider

    init(id: String, quote: Result<Decimal, ProviderFailure>, clock: any TimeProvider) {
        info = ProviderInfo(id: id, name: id.uppercased(), capabilities: [.quotes, .search, .history],
                            limits: ProviderLimits(requestsPerMinute: 100), requiresAPIKey: false, quoteDelay: .endOfDay,
                            termsURL: nil, signupURL: nil, coverageKey: "x")
        quoteResult = quote
        self.clock = clock
    }

    func search(_ query: String) async throws -> [InstrumentSearchResult] {
        [InstrumentSearchResult(providerID: info.id, symbol: "ABC", name: "ABC Corp", kind: .stock, mic: MIC(rawValue: "XNAS"),
                                ticker: Ticker(rawValue: "ABC"), currency: .usd)]
    }

    func quote(_ symbol: ProviderSymbol) async throws -> Sourced<Quote> {
        calls += 1
        let price = try quoteResult.get()
        return Sourced(Quote(listing: symbol.listing, price: price, currency: .usd),
                       metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), marketTimestamp: clock.now(),
                                              currency: .usd, delay: .endOfDay, quality: .validated))
    }

    func history(_ symbol: ProviderSymbol, range: DateRange) async throws -> Sourced<PriceSeries> {
        let bars = (0..<5).map { PriceBar(date: range.end.adding(days: -$0), close: Decimal(100 + $0)) }
        return Sourced(PriceSeries(listing: symbol.listing, currency: .usd, adjustment: .split, bars: bars),
                       metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), delay: .endOfDay, quality: .validated))
    }
}

final class MarketDataServiceTests: XCTestCase {
    let clock = ManualTimeProvider(Date.utc("2026-11-20T15:00:00Z"))
    let listing = Listing(instrumentID: InstrumentID(), mic: MIC(rawValue: "XNAS"), ticker: Ticker(rawValue: "ABC")!, tradingCurrency: .usd,
                          providerSymbols: ["a": "ABC", "b": "ABC"])

    func cache() throws -> DatabaseStore {
        try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: clock.now())
    }

    func testFallsBackToNextProviderAndCachesResult() async throws {
        let a = ScriptedProvider(id: "a", quote: .failure(.rateLimited(retryAfter: nil)), clock: clock)
        let b = ScriptedProvider(id: "b", quote: .success(101), clock: clock)
        let service = MarketDataService(registry: ProviderRegistry(marketData: [a, b]), cache: try cache(), clock: clock)
        let outcome = await service.quote(for: listing)
        XCTAssertEqual(outcome.value?.value.price, 101)
        XCTAssertEqual(outcome.value?.metadata.source.id, "b")
        XCTAssertEqual(outcome.failures, [ProviderAttempt(providerID: "a", failure: .rateLimited(retryAfter: nil))])

        // Within the freshness window the cache answers and no provider is called.
        let again = await service.quote(for: listing)
        XCTAssertEqual(again.value?.metadata.delay, .cached)
        XCTAssertEqual(b.calls, 1)
    }

    func testOutageServesStaleCacheAndNeverDeletesIt() async throws {
        let store = try cache()
        let provider = ScriptedProvider(id: "a", quote: .success(100), clock: clock)
        let service = MarketDataService(registry: ProviderRegistry(marketData: [provider]), cache: store, clock: clock)
        _ = await service.quote(for: listing)
        provider.quoteResult = .failure(.offline)
        clock.advance(by: 3600)
        let outcome = await service.quote(for: listing)
        XCTAssertEqual(outcome.value?.value.price, 100)
        XCTAssertEqual(outcome.value?.metadata.delay, .stale, "cached data served during an outage is labelled stale")
        XCTAssertTrue(outcome.isStale)
        let key = listing.key
        let stored = try await store.read { try CacheRecords.quote(key, in: $0) }
        XCTAssertNotNil(stored)
    }

    func testNoDataAtAllReportsFailuresWithoutInventingValues() async throws {
        let provider = ScriptedProvider(id: "a", quote: .failure(.offline), clock: clock)
        let service = MarketDataService(registry: ProviderRegistry(marketData: [provider]), cache: try cache(), clock: clock)
        let outcome = await service.quote(for: listing)
        XCTAssertNil(outcome.value)
        XCTAssertEqual(outcome.failures.first?.failure, .offline)
    }

    func testConflictingSourcesAreFlagged() async throws {
        let store = try cache()
        let a = ScriptedProvider(id: "a", quote: .success(100), clock: clock)
        _ = await MarketDataService(registry: ProviderRegistry(marketData: [a]), cache: store, clock: clock).quote(for: listing)
        let b = ScriptedProvider(id: "b", quote: .success(103), clock: clock)
        let outcome = await MarketDataService(registry: ProviderRegistry(marketData: [b]), cache: store, clock: clock)
            .quote(for: listing, forceRefresh: true)
        XCTAssertEqual(outcome.value?.metadata.quality, .conflicting)
        XCTAssertEqual(outcome.value?.metadata.conflicts.first?.value, 100)
    }

    func testSearchMergesProvidersAndHistoryIsCached() async throws {
        let a = ScriptedProvider(id: "a", quote: .success(1), clock: clock)
        let b = ScriptedProvider(id: "b", quote: .success(1), clock: clock)
        let service = MarketDataService(registry: ProviderRegistry(marketData: [a, b]), cache: try cache(), clock: clock)
        let search = await service.search("abc")
        XCTAssertEqual(search.results.count, 1, "the same MIC+ticker from two providers is one result")
        let range = DateRange(start: LocalDate.d("2026-11-14"), end: LocalDate.d("2026-11-20"))
        let history = await service.history(for: listing, range: range)
        XCTAssertEqual(history.value?.value.bars.count, 5)
        let tooShort = await service.search(String(repeating: "x", count: 100))
        XCTAssertTrue(tooShort.results.isEmpty)
    }

    func testDemoRegistryServesSyntheticQuotes() async throws {
        let demo = try XCTUnwrap(DemoUniverse.all.first)
        let service = MarketDataService(registry: .demo(clock: clock), cache: try cache(), clock: clock)
        let outcome = await service.quote(for: demo.listing)
        XCTAssertEqual(outcome.value?.metadata.delay, .synthetic)
        let cached = await service.quote(for: demo.listing)
        XCTAssertEqual(cached.value?.metadata.delay, .synthetic, "synthetic data keeps its label when served from cache")
    }

    func testExchangeRatesCachedAndCZKPrefersCNB() async throws {
        let store = try cache()
        let demo = DemoDataProvider(clock: clock)
        let service = ExchangeRateService(providers: [demo], cache: store, clock: clock)
        let rate = await service.rate(from: .eur, to: .czk, on: LocalDate.d("2026-11-20"))
        XCTAssertNotNil(rate.value)
        let inverse = await service.rate(from: .czk, to: .eur, on: LocalDate.d("2026-11-20"))
        XCTAssertEqual(inverse.value?.metadata.delay, .synthetic)
        XCTAssertEqual((inverse.value!.value * rate.value!.value).rounded(scale: 10), 1)
        let identity = await service.rate(from: .usd, to: .usd, on: LocalDate.d("2026-11-20"))
        XCTAssertEqual(identity.value?.value, 1)
    }

    func testSymbolMapping() {
        let sap = Listing(instrumentID: InstrumentID(), mic: MIC(rawValue: "XETR"), ticker: Ticker(rawValue: "SAP")!, tradingCurrency: .eur)
        XCTAssertEqual(SymbolMapper.symbol(for: sap, providerID: AlphaVantageProvider.id)?.symbol, "SAP.DEX")
        XCTAssertNil(SymbolMapper.symbol(for: sap, providerID: MassiveProvider.id), "Massive covers US listings only")
        let us = Listing(instrumentID: InstrumentID(), mic: MIC(rawValue: "XNYS"), ticker: Ticker(rawValue: "KO")!, tradingCurrency: .usd)
        XCTAssertEqual(SymbolMapper.symbol(for: us, providerID: FinnhubProvider.id)?.symbol, "KO")
    }

    func testRegistryOnlyEnablesProvidersWithKeys() {
        let gateway = ProviderGateway(client: OfflineHTTPClient(), clock: clock)
        var prefs = UserPreferences()
        prefs.providerSettings = [ProviderSetting(id: FinnhubProvider.id, enabled: true, priority: 0),
                                  ProviderSetting(id: AlphaVantageProvider.id, enabled: true, priority: 1)]
        let registry = ProviderCatalog.makeRegistry(preferences: prefs, credentials: StaticCredentials([FinnhubProvider.id: "k"]),
                                                    gateway: gateway, clock: clock)
        XCTAssertEqual(registry.marketData.map(\.info.id), [FinnhubProvider.id])
        XCTAssertEqual(Set(registry.exchangeRates.map(\.info.id)), [CNBExchangeRateProvider.id, ECBExchangeRateProvider.id])
        XCTAssertFalse(registry.fundamentals.contains { $0.info.id == SECEdgarProvider.id }, "SEC needs a contact e-mail")
    }
}
