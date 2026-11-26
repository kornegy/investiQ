import XCTest
@testable import InvestiQServices
@testable import InvestiQData
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQContent
import InvestiQPersistence
import InvestiQTestSupport

final class NewsAndCalendarTests: XCTestCase {
    let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Press</title>
    <item><title>Monetary policy decisions</title><link>https://www.ecb.europa.eu/press/pr/date/2026/html/ecb.mp261029.en.html</link>
    <description><![CDATA[<p>The Governing Council today decided to keep the three key <b>ECB interest rates</b> unchanged &amp; …</p>]]></description>
    <pubDate>Thu, 29 Oct 2026 13:15:00 +0000</pubDate></item>
    <item><title>Insecure link</title><link>http://example.com/a</link><pubDate>Thu, 29 Oct 2026 13:15:00 +0000</pubDate></item>
    <item><title>No date</title><link>https://example.com/b</link></item>
    </channel></rss>
    """

    func testRSSParsingStripsMarkupAndRejectsUnsafeItems() throws {
        let items = OfficialNewsProvider.parse(Data(rss.utf8), feed: OfficialNewsProvider.feeds[0])
        XCTAssertEqual(items.count, 1, "http links and undated items are dropped")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.headline, "Monetary policy decisions")
        XCTAssertEqual(item.summary, "The Governing Council today decided to keep the three key ECB interest rates unchanged & …")
        XCTAssertEqual(item.publishedAt, Date.utc("2026-10-29T13:15:00Z"))
        XCTAssertEqual(item.providerCategory, "official:ecb")
    }

    func testClassifierCuesAndWordBoundaries() {
        let official = NewsClassifier.classify(headline: "ECB keeps interest rates unchanged", summary: nil, isOfficial: true)
        XCTAssertEqual(official.statementType, .officialRelease)
        XCTAssertEqual(official.uncertainty, .low)
        XCTAssertTrue(official.categories.contains(.centralBanks))
        XCTAssertTrue(official.categories.contains(.interestRates))
        let rumour = NewsClassifier.classify(headline: "Company reportedly in talks to merge", summary: nil, isOfficial: false)
        XCTAssertEqual(rumour.statementType, .rumour)
        XCTAssertEqual(rumour.cue, "reportedly")
        XCTAssertEqual(rumour.uncertainty, .high)
        XCTAssertEqual(NewsClassifier.classify(headline: "Opinion: markets look stretched", summary: nil, isOfficial: false).statementType, .opinion)
        XCTAssertEqual(NewsClassifier.classify(headline: "Economists expect slower growth", summary: nil, isOfficial: false).statementType, .forecast)
        let plain = NewsClassifier.classify(headline: "Unemployment fell to 3.1 % in October", summary: nil, isOfficial: false)
        XCTAssertEqual(plain.statementType, .reported)
        XCTAssertEqual(plain.categories, [.employment])
        let tricky = NewsClassifier.classify(headline: "Causal warning about soil quality", summary: nil, isOfficial: false)
        XCTAssertFalse(tricky.categories.contains(.usMarkets), "'usa' inside 'causal' is not a match")
        XCTAssertFalse(tricky.categories.contains(.geopolitics), "'war' inside 'warning' is not a match")
        XCTAssertFalse(tricky.categories.contains(.energy), "'oil' inside 'soil' is not a match")
        XCTAssertTrue(NewsClassifier.classify(headline: "Česká inflace zpomalila", summary: nil, isOfficial: false).categories
            .contains(.inflation), "Czech keywords are recognised")
    }

    func testDeduplicationAndMatching() {
        func article(_ url: String, _ headline: String, _ source: String, _ hours: Double) -> NewsArticle {
            let canonical = NewsDeduplicator.canonicalURL(URL(string: url)!)
            return NewsArticle(id: canonical, canonicalURL: canonical, url: URL(string: url)!, headline: headline, summary: nil,
                               sourceName: source, alsoReportedBy: [], providerID: "x", publishedAt: Date.utc("2026-11-20T12:00:00Z").addingTimeInterval(hours * 3600),
                               eventDate: nil, categories: [], statementType: .reported, statementCue: nil, uncertainty: .medium,
                               relatedInstrumentIDs: [], relatedSectors: [], isDemo: false)
        }
        XCTAssertFalse(NewsDeduplicator.isSameStory("ECB keeps rates unchanged", "ECB raises rates by 25 basis points"))
        XCTAssertTrue(NewsDeduplicator.isSameStory("Demo Chips Inc. reports quarterly revenue up 12 % year on year",
                                                   "Demo Chips Inc. quarterly revenue rises 12 % year on year, results show"))
        XCTAssertEqual(NewsDeduplicator.canonicalURL(URL(string: "http://WWW.Example.com/a/b/?utm_source=x#top")!), "https://example.com/a/b")
        let merged = NewsDeduplicator.merge([
            article("https://a.com/1", "Demo Chips reports quarterly revenue up 12 percent", "A", 0),
            article("https://b.com/9", "Demo Chips reports quarterly revenue up 12 percent today", "B", 3),
            article("https://a.com/1?ref=feed", "Different headline same link", "C", 1),
            article("https://c.com/5", "Unrelated story about energy prices", "D", 2),
        ])
        XCTAssertEqual(merged.count, 2)
        let story = merged.first { $0.sourceName == "A" }
        XCTAssertEqual(Set(story?.alsoReportedBy ?? []), ["B", "C"])

        let candidates = [NewsInstrumentMatcher.Candidate(id: InstrumentID(), name: "Demo Chips Inc.", tickers: ["DEMOCHIP"], sector: "Information Technology"),
                          NewsInstrumentMatcher.Candidate(id: InstrumentID(), name: "Demo Banka a.s.", tickers: ["DEMOBANK"], sector: "Financials")]
        XCTAssertEqual(NewsInstrumentMatcher.match(headline: "Demo Chips results", summary: nil, symbols: [], candidates: candidates).count, 1)
        XCTAssertEqual(NewsInstrumentMatcher.match(headline: "Bank news", summary: nil, symbols: ["demobank"], candidates: candidates).first?.name,
                       "Demo Banka a.s.")
    }

    func makeDemoServices() async throws -> (NewsService, CalendarService, InstrumentService, ManualTimeProvider) {
        let clock = ManualTimeProvider(Date.utc("2026-11-25T10:00:00Z"))
        let user = try DatabaseStore(file: nil, migrations: UserSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let cache = try DatabaseStore(file: nil, migrations: CacheSchema.migrations, policy: .inMemoryOnly, now: clock.now())
        let registry = ProviderRegistry.demo(clock: clock)
        let instruments = InstrumentService(store: user, clock: clock)
        try await instruments.seedDemoUniverse()
        return (NewsService(registry: registry, cache: cache, instruments: instruments, clock: clock),
                CalendarService(registry: registry, instruments: instruments, clock: clock), instruments, clock)
    }

    func testDemoNewsPipeline() async throws {
        let (news, _, _, _) = try await makeDemoServices()
        let outcome = try await news.refresh()
        XCTAssertFalse(outcome.isOffline)
        XCTAssertEqual(outcome.articles.count, DemoNewsProvider.items.count - 1, "the duplicate Demo Chips story is merged")
        XCTAssertTrue(outcome.articles.allSatisfy(\.isDemo))
        let chips = try XCTUnwrap(outcome.articles.first { $0.headline.hasPrefix("Demo Chips") })
        XCTAssertEqual(chips.relatedInstrumentIDs, [DemoUniverse.all[5].instrument.id])
        XCTAssertEqual(chips.alsoReportedBy.count, 1)
        XCTAssertTrue(chips.categories.contains(.corporateEarnings))
        XCTAssertEqual(outcome.articles.first { $0.sourceName == "Demo Central Bank" }?.statementType, .officialRelease)
        XCTAssertEqual(outcome.articles.first { $0.headline.contains("reportedly") }?.statementType, .rumour)
        // Refreshing again does not create duplicates.
        let again = try await news.refresh()
        XCTAssertEqual(again.articles.count, outcome.articles.count)
        let cached = try await news.cached()
        XCTAssertEqual(NewsDeduplicator.merge(cached).count, outcome.articles.count)
    }

    func testCalendarCombinesVerifiedEventsAndEarnings() async throws {
        let (_, calendar, _, _) = try await makeDemoServices()
        let outcome = try await calendar.upcoming(days: 60)
        XCTAssertEqual(outcome.bundledVerifiedOn, .d("2026-11-25"))
        let fed = try XCTUnwrap(outcome.events.first { $0.id == "fed-2026-12-09" })
        // 14:00 in New York on 9 Dec 2026 (EST, UTC−5) = 19:00 UTC.
        XCTAssertEqual(fed.instant, Date.utc("2026-12-09T19:00:00Z"))
        let ecb = try XCTUnwrap(outcome.events.first { $0.id == "ecb-2026-12-17" })
        XCTAssertNil(ecb.instant, "no time is invented when the source gives none")
        XCTAssertTrue(outcome.events.contains { $0.kind == .earningsReport && $0.instrumentID != nil })
        XCTAssertTrue(outcome.events.allSatisfy { $0.date >= .d("2026-11-25") && $0.date <= .d("2027-01-24") })
        XCTAssertEqual(outcome.events.map(\.date), outcome.events.map(\.date).sorted())
    }

    func testBundledCalendarIsSourcedAndConsistent() throws {
        let (events, _) = try EventCatalog.load()
        XCTAssertGreaterThanOrEqual(events.count, 40)
        XCTAssertTrue(events.allSatisfy { $0.sourceURL?.scheme == "https" && $0.verifiedOn != nil })
        XCTAssertTrue(events.allSatisfy { TimeZone(identifier: $0.timeZone) != nil })
        let moved = try XCTUnwrap(events.first { $0.status == .rescheduled })
        XCTAssertEqual(moved.previousDate, .d("2027-12-08"))
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    }
}
