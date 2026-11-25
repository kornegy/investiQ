import Foundation
import InvestiQCore
import InvestiQData
import InvestiQPersistence

/// Result of a data request: the best available value plus what went wrong on the way.
public struct DataOutcome<Value: Sendable>: Sendable {
    public var value: Sourced<Value>?
    /// Failures of providers tried, in order (for the "why is this stale/missing?" explanation).
    public var failures: [ProviderAttempt]

    public init(value: Sourced<Value>?, failures: [ProviderAttempt]) {
        self.value = value
        self.failures = failures
    }

    public var isStale: Bool { value?.metadata.delay == .stale }
}

public struct ProviderAttempt: Sendable, Equatable {
    public var providerID: String
    public var failure: ProviderFailure
    public init(providerID: String, failure: ProviderFailure) { self.providerID = providerID; self.failure = failure }
}

/// Freshness windows (docs/DATA_PROVIDERS.md §4).
public struct FreshnessPolicy: Sendable {
    public var quote: TimeInterval = 15 * 60
    public var history: TimeInterval = 12 * 3600
    public var fundamentals: TimeInterval = 7 * 24 * 3600
    public init() {}
}

/// Orchestrates providers, cache, validation and conflict detection for market data (ADR-007).
/// Provider outages never delete cached data; stale cache is served with an explicit `stale` label.
public actor MarketDataService {
    private let registry: ProviderRegistry
    private let cache: DatabaseStore
    private let clock: any TimeProvider
    private let freshness: FreshnessPolicy

    public init(registry: ProviderRegistry, cache: DatabaseStore, clock: any TimeProvider, freshness: FreshnessPolicy = FreshnessPolicy()) {
        self.registry = registry
        self.cache = cache
        self.clock = clock
        self.freshness = freshness
    }

    public var hasMarketProviders: Bool { !registry.marketData.isEmpty }

    // MARK: Search

    public struct SearchOutcome: Sendable {
        public var results: [InstrumentSearchResult]
        public var failures: [ProviderAttempt]
    }

    /// Searches all enabled providers concurrently and merges results (same ISIN or same MIC+ticker = one hit).
    public func search(_ query: String, limit: Int = 50) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1, trimmed.count <= 64 else { return SearchOutcome(results: [], failures: []) }
        let providers = registry.marketData.filter { $0.info.capabilities.contains(.search) }
        var results: [InstrumentSearchResult] = []
        var failures: [ProviderAttempt] = []
        await withTaskGroup(of: (String, Result<[InstrumentSearchResult], ProviderFailure>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.info.id, .success(try await provider.search(trimmed))) } catch {
                        return (provider.info.id, .failure(error as? ProviderFailure ?? .connectionFailed))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let hits): results += hits
                case .failure(let failure): failures.append(ProviderAttempt(providerID: id, failure: failure))
                }
            }
        }
        // Keep provider priority order, then de-duplicate.
        let order = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($1.info.id, $0) })
        results.sort { (order[$0.providerID] ?? 0) < (order[$1.providerID] ?? 0) }
        var seen = Set<String>()
        let merged = results.filter { hit in
            let key = hit.isin?.rawValue ?? "\(hit.mic?.rawValue ?? hit.exchangeName ?? "?"):\(hit.ticker?.rawValue ?? hit.symbol)"
            return seen.insert(key).inserted
        }
        return SearchOutcome(results: Array(merged.prefix(limit)), failures: failures)
    }

    // MARK: Quotes

    public func quote(for listing: Listing, forceRefresh: Bool = false) async -> DataOutcome<Quote> {
        let cached = try? await cache.read { try CacheRecords.quote(listing.key, in: $0) }
        if !forceRefresh, let cached, clock.now().timeIntervalSince(cached.metadata.retrievedAt) < freshness.quote {
            return DataOutcome(value: relabelCached(cached), failures: [])
        }
        var failures: [ProviderAttempt] = []
        for provider in registry.marketData where provider.info.capabilities.contains(.quotes) {
            guard let symbol = SymbolMapper.symbol(for: listing, providerID: provider.info.id) else { continue }
            do {
                var fresh = try await provider.quote(symbol)
                if let cached, cached.metadata.source.id != fresh.metadata.source.id, isSameMarketDay(cached, fresh),
                   ConflictDetector.isConflicting(cached.value.price, fresh.value.price) {
                    fresh.metadata.quality = .conflicting
                    fresh.metadata.conflicts = [ConflictingValue(source: cached.metadata.source, value: cached.value.price)]
                }
                let toStore = fresh
                try? await cache.write { try CacheRecords.saveQuote(toStore, in: $0) }
                return DataOutcome(value: fresh, failures: failures)
            } catch {
                let failure = error as? ProviderFailure ?? .connectionFailed
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: failure))
                if !failure.allowsFallback { break }
            }
        }
        return DataOutcome(value: cached.map(markStale), failures: failures)
    }

    private func isSameMarketDay(_ a: Sourced<Quote>, _ b: Sourced<Quote>) -> Bool {
        guard let ta = a.metadata.marketTimestamp, let tb = b.metadata.marketTimestamp else { return false }
        return abs(ta.timeIntervalSince(tb)) < 24 * 3600
    }

    private func relabelCached<T>(_ value: Sourced<T>) -> Sourced<T> {
        var copy = value
        // Synthetic/manual labels are kept; real provider data served from cache is labelled as such.
        if case .synthetic = copy.metadata.delay { return copy }
        if case .manual = copy.metadata.delay { return copy }
        copy.metadata.delay = .cached
        return copy
    }

    private func markStale<T>(_ value: Sourced<T>) -> Sourced<T> {
        var copy = value
        if case .synthetic = copy.metadata.delay { return copy }
        copy.metadata.delay = .stale
        return copy
    }

    // MARK: History

    public func history(for listing: Listing, range: DateRange, forceRefresh: Bool = false) async -> DataOutcome<PriceSeries> {
        let cached = try? await cache.read { try CacheRecords.series(listing.key, in: $0) }
        if !forceRefresh, let cached, clock.now().timeIntervalSince(cached.metadata.retrievedAt) < freshness.history,
           let first = cached.value.firstDate, first <= range.start.adding(days: 7) {
            return DataOutcome(value: relabelCached(cached).map { $0.filtered(to: range) }, failures: [])
        }
        var failures: [ProviderAttempt] = []
        for provider in registry.marketData where provider.info.capabilities.contains(.history) {
            guard let symbol = SymbolMapper.symbol(for: listing, providerID: provider.info.id) else { continue }
            do {
                let fresh = try await provider.history(symbol, range: range)
                guard !fresh.value.bars.isEmpty else { throw ProviderFailure.notFound }
                try? await cache.write { try CacheRecords.saveSeries(fresh, in: $0) }
                return DataOutcome(value: fresh, failures: failures)
            } catch {
                let failure = error as? ProviderFailure ?? .connectionFailed
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: failure))
                if !failure.allowsFallback { break }
            }
        }
        return DataOutcome(value: cached.map { markStale($0).map { $0.filtered(to: range) } }, failures: failures)
    }

    // MARK: Fundamentals

    public func fundamentals(for listing: Listing, forceRefresh: Bool = false) async -> DataOutcome<FundamentalsSnapshot> {
        let cached = try? await cache.read { try CacheRecords.fundamentals(listing.key, in: $0) }
        if !forceRefresh, let cached, clock.now().timeIntervalSince(cached.metadata.retrievedAt) < freshness.fundamentals {
            return DataOutcome(value: relabelCached(cached), failures: [])
        }
        var failures: [ProviderAttempt] = []
        for provider in registry.fundamentals {
            guard let symbol = SymbolMapper.symbol(for: listing, providerID: provider.info.id) else { continue }
            do {
                let fresh = try await provider.fundamentals(symbol)
                try? await cache.write { try CacheRecords.saveFundamentals(fresh, for: listing.key, in: $0) }
                return DataOutcome(value: fresh, failures: failures)
            } catch {
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: error as? ProviderFailure ?? .connectionFailed))
            }
        }
        return DataOutcome(value: cached.map(markStale), failures: failures)
    }

    // MARK: Bonds & ETFs (extension points; demo/manual data in v1)

    public func bondDetails(isin: ISIN) async -> Sourced<BondDetails>? {
        for provider in registry.bonds {
            if let details = try? await provider.bondDetails(isin: isin) { return details }
        }
        return nil
    }

    public func etfDetails(isin: ISIN) async -> Sourced<ETFDetails>? {
        for provider in registry.etfs {
            if let details = try? await provider.etfDetails(isin: isin) { return details }
        }
        return nil
    }
}

extension PriceSeries {
    func filtered(to range: DateRange) -> PriceSeries {
        var copy = self
        copy.bars = bars.filter { $0.date >= range.start && $0.date <= range.end }
        return copy
    }
}
