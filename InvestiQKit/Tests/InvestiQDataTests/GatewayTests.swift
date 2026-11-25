import XCTest
@testable import InvestiQData
import InvestiQCore
import InvestiQTestSupport

final class GatewayTests: XCTestCase {
    let provider = ProviderInfo(id: "test", name: "Test", capabilities: [.quotes], limits: ProviderLimits(requestsPerMinute: 2, requestsPerDay: 3, maximumWaitSeconds: 60),
                                requiresAPIKey: false, quoteDelay: .endOfDay, termsURL: nil, signupURL: nil, coverageKey: "x")
    let url = URL(string: "https://example.com/data")!

    func makeGateway(_ client: MockHTTPClient, sleeper: RecordingSleeper = RecordingSleeper(),
                     clock: ManualTimeProvider = ManualTimeProvider(Date(timeIntervalSince1970: 1_800_000_000))) -> ProviderGateway {
        ProviderGateway(client: client, clock: clock, sleeper: sleeper, jitter: { 0.5 })
    }

    func testRetriesTransientServerErrorsThenSucceeds() async throws {
        let client = MockHTTPClient()
        client.on("example.com", status: 503, body: Data())
        client.on("example.com", status: 200, body: Data("ok".utf8))
        let sleeper = RecordingSleeper()
        let data = try await makeGateway(client, sleeper: sleeper).fetch(HTTPRequest(url: url), provider: provider)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(sleeper.sleeps, [0.25]) // 0.5 s base × 2^0 × jitter 0.5
    }

    func testDoesNotRetryAuthorizationErrors() async {
        let client = MockHTTPClient()
        client.on("example.com", status: 401, body: Data())
        do {
            _ = try await makeGateway(client).fetch(HTTPRequest(url: url), provider: provider)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .unauthorized)
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testStatusMapping() {
        func map(_ status: Int, headers: [String: String] = [:]) -> ProviderFailure? {
            do { _ = try ProviderGateway.check(HTTPResponse(statusCode: status, headers: headers, body: Data())); return nil } catch {
                return error as? ProviderFailure
            }
        }
        XCTAssertNil(map(204))
        XCTAssertEqual(map(403), .notSupported)
        XCTAssertEqual(map(404), .notFound)
        XCTAssertEqual(map(429, headers: ["retry-after": "7"]), .rateLimited(retryAfter: 7))
        XCTAssertEqual(map(502), .serverError(502))
        XCTAssertEqual(ProviderGateway.map(TransportError.offline), .offline)
    }

    func testRateLimiterWaitsThenEnforcesDailyQuota() async throws {
        let client = MockHTTPClient()
        client.on("example.com", body: Data("ok".utf8))
        let sleeper = RecordingSleeper()
        let gateway = makeGateway(client, sleeper: sleeper)
        for _ in 0..<3 { _ = try await gateway.fetch(HTTPRequest(url: url), provider: provider) }
        XCTAssertEqual(sleeper.sleeps.count, 1, "third request within the minute must wait for a token")
        XCTAssertEqual(sleeper.sleeps.first ?? 0, 30, accuracy: 0.01) // 2 per minute → 30 s per token
        do {
            _ = try await gateway.fetch(HTTPRequest(url: url), provider: provider)
            XCTFail("daily quota exceeded")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .quotaExhausted)
        }
    }

    func testConcurrentIdenticalRequestsAreDeduplicated() async throws {
        let client = MockHTTPClient()
        client.delayNanoseconds = 50_000_000
        client.on("example.com", body: Data("shared".utf8))
        let many = ProviderInfo(id: "many", name: "Many", capabilities: [], limits: ProviderLimits(requestsPerMinute: 100),
                                requiresAPIKey: false, quoteDelay: .endOfDay, termsURL: nil, signupURL: nil, coverageKey: "x")
        let gateway = makeGateway(client)
        let request = HTTPRequest(url: url)
        async let a = gateway.fetch(request, provider: many)
        async let b = gateway.fetch(request, provider: many)
        let results = try await [a, b]
        XCTAssertEqual(results.map { String(decoding: $0, as: UTF8.self) }, ["shared", "shared"])
        XCTAssertEqual(client.requests.count, 1)
    }

    func testRedactedKeyHidesSecrets() {
        let request = HTTPRequest(url: URL(string: "https://x.example/q?symbol=A&apikey=SECRET")!, headers: ["X-Finnhub-Token": "TOKEN"])
        XCTAssertFalse(request.redactedKey.contains("SECRET"))
        XCTAssertFalse(request.redactedKey.contains("TOKEN"))
    }

    func testValidatorCleansSeries() {
        let key = ListingKey(mic: nil, ticker: Ticker(rawValue: "T")!)
        let series = PriceSeries(listing: key, currency: .usd, adjustment: .split, bars: [
            PriceBar(date: .init(iso: "2026-01-02")!, open: 10, high: 11, low: 9, close: 10.5),
            PriceBar(date: .init(iso: "2026-01-02")!, close: 10.5),
            PriceBar(date: .init(iso: "2026-01-05")!, open: 10, high: 9, low: 8, close: 9.5), // high below open
            PriceBar(date: .init(iso: "2026-01-06")!, close: -1),
            PriceBar(date: .init(iso: "2027-01-01")!, close: 10),
        ])
        let (cleaned, dropped) = DataValidator.clean(series, today: LocalDate(iso: "2026-01-10")!)
        XCTAssertEqual(cleaned.bars.count, 1)
        XCTAssertEqual(dropped, 4)
        XCTAssertTrue(ConflictDetector.isConflicting(100, 102))
        XCTAssertFalse(ConflictDetector.isConflicting(100, 100.5))
    }
}
