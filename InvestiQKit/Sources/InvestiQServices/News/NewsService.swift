import Foundation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence

public struct NewsOutcome: Sendable {
    public var articles: [NewsArticle]
    public var failures: [ProviderAttempt]
    /// True when no provider could be reached and only cached items are shown.
    public var isOffline: Bool
}

/// News pipeline (spec §16, M-NEWS): fetch → classify → match instruments → deduplicate → cache.
/// Fetching happens only when the user opens or refreshes the News section.
public actor NewsService {
    /// Items are kept this many days in the cache.
    public static let retentionDays = 30
    public static let fetchLimit = 50

    private let registry: ProviderRegistry
    private let cache: DatabaseStore
    private let instruments: InstrumentService
    private let clock: any TimeProvider

    public init(registry: ProviderRegistry, cache: DatabaseStore, instruments: InstrumentService, clock: any TimeProvider) {
        self.registry = registry
        self.cache = cache
        self.instruments = instruments
        self.clock = clock
    }

    public func cached() async throws -> [NewsArticle] {
        let since = clock.now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        return try await cache.read { try NewsRecords.recent(since: since, limit: 500, in: $0) }
    }

    public func refresh() async throws -> NewsOutcome {
        let library = try await instruments.library()
        let candidates = library.map { entry in
            NewsInstrumentMatcher.Candidate(id: entry.id, name: entry.instrument.name,
                                            tickers: entry.listing.map { [$0.ticker.rawValue] } ?? [], sector: entry.instrument.sector)
        }
        let symbols = library.compactMap { $0.listing?.ticker.rawValue }
        var raw: [RawNewsItem] = []
        var failures: [ProviderAttempt] = []
        for provider in registry.news {
            do {
                raw += try await provider.latestNews(symbols: symbols, limit: Self.fetchLimit)
            } catch {
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: error as? ProviderFailure ?? .connectionFailed))
            }
        }
        let fresh = raw.map { Self.process($0, candidates: candidates) }
        let merged = NewsDeduplicator.merge(try await cached() + fresh)
        let now = clock.now()
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        try await cache.write { db in
            for article in merged { try NewsRecords.upsert(article, fetchedAt: now, in: db) }
            try NewsRecords.purge(before: cutoff, in: db)
        }
        return NewsOutcome(articles: merged, failures: failures, isOffline: raw.isEmpty && !registry.news.isEmpty && !failures.isEmpty)
    }

    static func process(_ item: RawNewsItem, candidates: [NewsInstrumentMatcher.Candidate]) -> NewsArticle {
        let official = item.providerCategory?.hasPrefix("official") == true
        let classification = NewsClassifier.classify(headline: item.headline, summary: item.summary, isOfficial: official)
        let matches = NewsInstrumentMatcher.match(headline: item.headline, summary: item.summary, symbols: item.relatedSymbols,
                                                  candidates: candidates)
        let sectors = Set(matches.compactMap(\.sector)).union(NewsClassifier.sectors(for: classification.categories)).sorted()
        let canonical = NewsDeduplicator.canonicalURL(item.url)
        let utc = TimeZone(identifier: "UTC") ?? .current
        return NewsArticle(id: canonical, canonicalURL: canonical, url: item.url, headline: item.headline, summary: item.summary,
                           sourceName: item.sourceName, alsoReportedBy: [], providerID: item.providerID, publishedAt: item.publishedAt,
                           eventDate: official ? LocalDate(item.publishedAt, timeZone: utc) : nil, categories: classification.categories,
                           statementType: classification.statementType, statementCue: classification.cue,
                           uncertainty: classification.uncertainty, relatedInstrumentIDs: matches.map(\.id), relatedSectors: sectors,
                           isDemo: item.providerID == DemoNewsProvider.providerID)
    }
}
