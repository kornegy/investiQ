import XCTest
@testable import InvestiQData
import InvestiQCore
import InvestiQTestSupport

/// API contract tests against fixtures built from the providers' documented formats
/// (docs/DATA_PROVIDERS.md §3). No test touches the network.
final class ProviderContractTests: XCTestCase {
    let clock = ManualTimeProvider(InstantCoding.date(from: "2026-11-21T12:00:00Z")!)
    let credentials = StaticCredentials([AlphaVantageProvider.id: "AVKEY", FinnhubProvider.id: "FHKEY", TwelveDataProvider.id: "TDKEY",
                                         FinancialModelingPrepProvider.id: "FMPKEY", MassiveProvider.id: "MSKEY", FREDProvider.id: "FREDKEY"])
    var client: MockHTTPClient!
    var gateway: ProviderGateway!

    override func setUp() { reset() }

    func reset() {
        client = MockHTTPClient()
        gateway = ProviderGateway(client: client, clock: clock, sleeper: RecordingSleeper(), jitter: { 0 })
    }

    func fixture(_ name: String) throws -> Data { try Fixtures.data(name, bundle: .module) }

    func usSymbol(_ provider: String, _ symbol: String) -> ProviderSymbol {
        ProviderSymbol(providerID: provider, symbol: symbol, listing: ListingKey(mic: MIC(rawValue: "XNAS"), ticker: Ticker(rawValue: symbol)!), currency: .usd)
    }

    // MARK: Alpha Vantage

    func testAlphaVantageQuote() async throws {
        client.on("GLOBAL_QUOTE", body: try fixture("alphavantage_global_quote.json"))
        let av = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
        let quote = try await av.quote(usSymbol(av.info.id, "IBM"))
        XCTAssertEqual(quote.value.price, Decimal(string: "224.77"))
        XCTAssertEqual(quote.value.changePercent, Decimal(string: "1.2295"))
        XCTAssertEqual(quote.metadata.delay, .endOfDay, "free Alpha Vantage data must never be labelled real-time")
        XCTAssertEqual(quote.metadata.source.id, "alphavantage")
    }

    func testAlphaVantageErrorsInHTTP200Body() async throws {
        let av = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
        for (fixtureName, expected) in [("alphavantage_global_quote_empty.json", ProviderFailure.notFound),
                                        ("alphavantage_rate_limit.json", .quotaExhausted),
                                        ("alphavantage_premium.json", .notSupported),
                                        ("alphavantage_error.json", .notFound)] {
            reset()
            client.on("GLOBAL_QUOTE", body: try fixture(fixtureName))
            let provider = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
            do {
                _ = try await provider.quote(usSymbol(av.info.id, "IBM"))
                XCTFail("expected \(expected) for \(fixtureName)")
            } catch {
                XCTAssertEqual(error as? ProviderFailure, expected, fixtureName)
            }
        }
    }

    func testAlphaVantageHistoryDropsInvalidBarsAndLabelsUnadjusted() async throws {
        client.on("TIME_SERIES_DAILY", body: try fixture("alphavantage_daily.json"))
        let av = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
        let range = DateRange(start: LocalDate(iso: "2026-01-01")!, end: LocalDate(iso: "2026-11-21")!)
        let series = try await av.history(usSymbol(av.info.id, "IBM"), range: range)
        XCTAssertEqual(series.value.bars.map(\.date.iso), ["2026-11-18", "2026-11-19", "2026-11-20"])
        XCTAssertEqual(series.value.adjustment, .unadjusted)
        XCTAssertEqual(series.metadata.quality, .partial)
    }

    func testAlphaVantageOverviewMapsSentinelsToMissing() async throws {
        client.on("OVERVIEW", body: try fixture("alphavantage_overview.json"))
        let av = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
        let snapshot = try await av.fundamentals(usSymbol(av.info.id, "IBM")).value
        XCTAssertEqual(snapshot.peRatio, Decimal(string: "32.5"))
        XCTAssertEqual(snapshot.dividendYield, Decimal(string: "0.0297"))
        XCTAssertNil(snapshot.freeCashFlowTTM, "not provided → missing, never zero")
        XCTAssertEqual(snapshot.currency, .usd)
    }

    func testAlphaVantageSearchMapsSuffixesToMIC() async throws {
        client.on("SYMBOL_SEARCH", body: try fixture("alphavantage_search.json"))
        let results = try await AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock).search("tesco")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].mic?.rawValue, "XLON")
        XCTAssertEqual(results[0].ticker?.rawValue, "TSCO")
        XCTAssertEqual(results[1].mic?.rawValue, "XETR")
        XCTAssertEqual(results[2].kind, .etf)
        XCTAssertTrue(client.requests.allSatisfy { !$0.redactedKey.contains("AVKEY") })
    }

    func testMissingAPIKeyFailsWithoutRequest() async {
        let provider = AlphaVantageProvider(gateway: gateway, credentials: StaticCredentials([:]), clock: clock)
        do {
            _ = try await provider.search("x")
            XCTFail("expected missing key")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .missingAPIKey)
            XCTAssertTrue(client.requests.isEmpty)
        }
    }

    // MARK: Finnhub

    func testFinnhubQuoteUsesHeaderTokenAndRejectsZeroSentinel() async throws {
        client.on("/quote", body: try fixture("finnhub_quote.json"))
        let finnhub = FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock)
        let quote = try await finnhub.quote(usSymbol(finnhub.info.id, "AAPL"))
        XCTAssertEqual(quote.value.price, Decimal(string: "261.74"))
        XCTAssertEqual(quote.metadata.delay, .delayed(minutes: 15))
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertFalse(request.url.absoluteString.contains("FHKEY"), "token must travel in a header")
        XCTAssertEqual(request.headers["X-Finnhub-Token"], "FHKEY")

        reset()
        client.on("/quote", body: try fixture("finnhub_quote_unknown.json"))
        do {
            _ = try await FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock).quote(usSymbol("finnhub", "NOPE"))
            XCTFail("all-zero quote must be notFound")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .notFound)
        }
    }

    func testFinnhubFundamentalsScaleUnits() async throws {
        client.on("/stock/profile2", body: try fixture("finnhub_profile.json"))
        client.on("/stock/metric", body: try fixture("finnhub_metric.json"))
        let snapshot = try await FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock).fundamentals(usSymbol("finnhub", "AAPL")).value
        XCTAssertEqual(snapshot.marketCapitalization, Decimal(string: "3500000500000"))
        XCTAssertEqual(snapshot.operatingMargin, Decimal(string: "0.315"))
        XCTAssertEqual(snapshot.dividendYield, Decimal(string: "0.0044"))
        XCTAssertNil(snapshot.bookValuePerShare)
    }

    func testFinnhubNewsFiltersUnsafeOrIncompleteItems() async throws {
        client.on("/company-news", body: try fixture("finnhub_news.json"))
        let news = try await FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock).latestNews(symbols: ["AAPL"], limit: 10)
        XCTAssertEqual(news.map(\.headline), ["Apple reports quarterly results"])
        XCTAssertEqual(news.first?.relatedSymbols, ["AAPL"])
    }

    func testFinnhubEarningsAndHistoryNotSupported() async throws {
        client.on("/calendar/earnings", body: try fixture("finnhub_earnings.json"))
        let finnhub = FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock)
        let events = try await finnhub.earnings(range: DateRange(start: LocalDate(iso: "2026-12-01")!, end: LocalDate(iso: "2026-12-31")!))
        XCTAssertEqual(events.first?.symbol, "AAPL")
        XCTAssertNil(events.first?.epsActual)
        do {
            _ = try await finnhub.history(usSymbol("finnhub", "AAPL"), range: DateRange(start: LocalDate(iso: "2026-01-01")!, end: LocalDate(iso: "2026-02-01")!))
            XCTFail("candles are premium")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .notSupported)
        }
    }

    // MARK: Twelve Data

    func testTwelveDataQuoteHistoryAndErrors() async throws {
        client.on("/quote", body: try fixture("twelvedata_quote.json"))
        client.on("/time_series", body: try fixture("twelvedata_timeseries.json"))
        let td = TwelveDataProvider(gateway: gateway, credentials: credentials, clock: clock)
        let quote = try await td.quote(usSymbol(td.info.id, "AAPL"))
        XCTAssertEqual(quote.value.previousClose, Decimal(string: "259.45"))
        let series = try await td.history(usSymbol(td.info.id, "AAPL"),
                                          range: DateRange(start: LocalDate(iso: "2026-11-01")!, end: LocalDate(iso: "2026-11-21")!))
        XCTAssertEqual(series.value.bars.count, 2, "duplicate and future bars are dropped")
        XCTAssertEqual(series.value.adjustment, .split)
        XCTAssertTrue(client.requests.contains { $0.url.absoluteString.contains("adjust=splits") })

        reset()
        client.on("/quote", body: try fixture("twelvedata_error.json"))
        do {
            _ = try await TwelveDataProvider(gateway: gateway, credentials: credentials, clock: clock).quote(usSymbol("twelvedata", "AAPL"))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .unauthorized)
        }
    }

    // MARK: FMP, Massive

    func testFMPSearchByISINAndQuote() async throws {
        client.on("/search-isin", body: try fixture("fmp_search_isin.json"))
        client.on("/quote", body: try fixture("fmp_quote.json"))
        let fmp = FinancialModelingPrepProvider(gateway: gateway, credentials: credentials, clock: clock)
        let results = try await fmp.search("US0378331005")
        XCTAssertEqual(results.first?.isin?.rawValue, "US0378331005")
        let quote = try await fmp.quote(usSymbol(fmp.info.id, "AAPL"))
        XCTAssertEqual(quote.value.dayHigh, Decimal(string: "263.31"))

        reset()
        client.on("/quote", status: 401, body: try fixture("fmp_error.json"))
        do {
            _ = try await FinancialModelingPrepProvider(gateway: gateway, credentials: credentials, clock: clock).quote(usSymbol("fmp", "AAPL"))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .unauthorized)
        }
    }

    func testMassiveAggregatesAndSearch() async throws {
        client.on("/prev", body: try fixture("massive_prev.json"))
        client.on("/range/1/day", body: try fixture("massive_aggs.json"))
        client.on("/v3/reference/tickers", body: try fixture("massive_tickers.json"))
        let massive = MassiveProvider(gateway: gateway, credentials: credentials, clock: clock)
        let quote = try await massive.quote(usSymbol(massive.info.id, "AAPL"))
        XCTAssertEqual(quote.value.price, Decimal(string: "261.74"))
        XCTAssertEqual(quote.metadata.delay, .endOfDay)
        let series = try await massive.history(usSymbol(massive.info.id, "AAPL"),
                                               range: DateRange(start: LocalDate(iso: "2026-11-01")!, end: LocalDate(iso: "2026-11-21")!))
        XCTAssertEqual(series.value.bars.map(\.date.iso), ["2026-11-19", "2026-11-20"])
        let found = try await massive.search("apple")
        XCTAssertEqual(found.first?.mic?.rawValue, "XNAS")
        XCTAssertEqual(found.first?.currency, .usd)
        XCTAssertEqual(client.requests.first?.headers["Authorization"], "Bearer MSKEY")
    }

    func testNonJSONResponsesAreRejected() async throws {
        client.on("/quote", body: try fixture("html_error.html"))
        do {
            _ = try await FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock).quote(usSymbol("finnhub", "AAPL"))
            XCTFail("HTML must be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .invalidResponse("not JSON"))
        }
    }

    // MARK: Exchange rates and macro

    func testECBRatesParsedByHeaderAndConverted() async throws {
        client.on("data-api.ecb.europa.eu", body: try fixture("ecb_exr.csv"))
        let ecb = ECBExchangeRateProvider(gateway: gateway, clock: clock)
        let rates = try await ecb.rates(base: .eur, quotes: [.czk, .usd], on: LocalDate(iso: "2026-11-20")!)
        XCTAssertEqual(rates.value.first { $0.quote == .czk }?.rate, Decimal(string: "24.95"))
        XCTAssertEqual(rates.value.first { $0.quote == .usd }?.rate, Decimal(string: "1.085"), "rows after the requested date are ignored")

        reset()
        client.on("data-api.ecb.europa.eu", body: try fixture("ecb_exr.csv"))
        let cross = try await ECBExchangeRateProvider(gateway: gateway, clock: clock).rates(base: .czk, quotes: [.usd], on: LocalDate(iso: "2026-11-20")!)
        XCTAssertEqual(cross.value.first?.rate, Decimal(string: "1.085")! / Decimal(string: "24.95")!)
    }

    func testCNBRatesNormalisedPerUnit() async throws {
        client.on("api.cnb.cz", body: try fixture("cnb_daily.json"))
        let cnb = CNBExchangeRateProvider(gateway: gateway, clock: clock)
        let rates = try await cnb.rates(base: .usd, quotes: [.czk], on: LocalDate(iso: "2026-11-20")!)
        XCTAssertEqual(rates.value.first?.rate, Decimal(string: "22.995"))
        let parsed = try CNBExchangeRateProvider.parse(try fixture("cnb_daily.json"))
        XCTAssertEqual(parsed[CurrencyCode(rawValue: "JPY")!]?.0, Decimal(string: "0.1482"), "JPY is quoted per 100 units")
    }

    func testFREDMissingObservationsStayMissing() async throws {
        client.on("api.stlouisfed.org", body: try fixture("fred_observations.json"))
        let fred = FREDProvider(gateway: gateway, credentials: credentials, clock: clock)
        let series = try await fred.series(id: "CPIAUCSL", range: DateRange(start: LocalDate(iso: "2026-01-01")!, end: LocalDate(iso: "2026-11-21")!))
        XCTAssertEqual(series.value.count, 3)
        XCTAssertNil(series.value[1].value, "FRED '.' means missing")
        XCTAssertEqual(series.value[2].value, 323.4)
        do {
            _ = try await fred.series(id: "BAD ID; DROP", range: DateRange(start: LocalDate(iso: "2026-01-01")!, end: LocalDate(iso: "2026-02-01")!))
            XCTFail("invalid series ids are rejected before any request")
        } catch {}
    }

    func testSECCompanyFactsAnnualStatements() async throws {
        client.on("company_tickers.json", body: try fixture("sec_company_tickers.json"))
        client.on("companyfacts", body: try fixture("sec_companyfacts.json"))
        let sec = SECEdgarProvider(gateway: gateway, clock: clock, contactEmail: "researcher@example.com")
        let snapshot = try await sec.fundamentals(usSymbol(SECEdgarProvider.id, "AAPL")).value
        XCTAssertEqual(snapshot.annualStatements.map(\.fiscalYear), [2024, 2025])
        XCTAssertEqual(snapshot.revenueTTM, Decimal(string: "416161000000"), "quarterly facts inside the 10-K are excluded")
        XCTAssertEqual(snapshot.freeCashFlowTTM, Decimal(string: "98767000000"))
        XCTAssertEqual(snapshot.revenueGrowthYoY, Decimal(string: "416161000000")! / Decimal(string: "391035000000")! - 1)
        XCTAssertEqual(snapshot.debtToEquity, Decimal(string: "90678000000")! / Decimal(string: "73733000000")!)
        XCTAssertTrue(client.requests.allSatisfy { $0.headers["User-Agent"]?.contains("researcher@example.com") == true })
        XCTAssertTrue(client.requests.contains { $0.url.absoluteString.contains("CIK0000320193") })

        let disabled = SECEdgarProvider(gateway: gateway, clock: clock, contactEmail: nil)
        do {
            _ = try await disabled.fundamentals(usSymbol(SECEdgarProvider.id, "AAPL"))
            XCTFail("SEC requires a contact e-mail")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .misconfigured("SEC contact e-mail required"))
        }
    }

    // MARK: Demo

    func testDemoProviderIsDeterministicAndLabelled() async throws {
        let demo = DemoDataProvider(clock: clock)
        let first = try XCTUnwrap(DemoUniverse.all.first)
        let symbol = DemoDataProvider.symbol(for: first)
        let range = DateRange(start: LocalDate(iso: "2025-01-01")!, end: LocalDate(iso: "2026-11-21")!)
        let a = try await demo.history(symbol, range: range)
        let b = try await demo.history(symbol, range: range)
        XCTAssertEqual(a.value.bars, b.value.bars)
        XCTAssertEqual(a.metadata.delay, .synthetic)
        XCTAssertEqual(a.metadata.source, .demo)
        XCTAssertLessThanOrEqual(a.value.lastDate!, LocalDate(iso: "2026-11-21")!, "demo data never extends into the future")
        let quote = try await demo.quote(symbol)
        XCTAssertEqual(quote.value.price, a.value.bars.last?.close)
        for instrument in DemoUniverse.all {
            XCTAssertTrue(instrument.instrument.name.hasPrefix("Demo"))
            XCTAssertEqual(instrument.instrument.isin?.countryCode, "ZZ", "demo ISINs use the unassigned ZZ prefix")
        }
        let isinHits = try await demo.search(first.instrument.isin!.rawValue)
        XCTAssertEqual(isinHits.count, 1)
        let rates = try await demo.rates(base: .eur, quotes: [.czk, .usd], on: LocalDate(iso: "2026-11-21")!)
        XCTAssertEqual(rates.value.count, 2)
    }
}
