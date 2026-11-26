import Foundation
import InvestiQCore
import InvestiQData
import InvestiQPersistence

/// Exchange rates for valuation and conversion. Cached per date; CZK pairs prefer the CNB fixing,
/// euro pairs the ECB reference rate (docs/FINANCIAL_METHODOLOGY.md §1).
public actor ExchangeRateService {
    private let providers: [any ExchangeRateProvider]
    private let cache: DatabaseStore
    private let clock: any TimeProvider
    /// Weekends and holidays: use the last published rate within this window.
    static let maxAgeDays = 7

    public init(providers: [any ExchangeRateProvider], cache: DatabaseStore, clock: any TimeProvider) {
        self.providers = providers
        self.cache = cache
        self.clock = clock
    }

    /// Units of `to` per 1 unit of `from` on `date` (or the last publication before it).
    public func rate(from: CurrencyCode, to: CurrencyCode, on date: LocalDate) async -> DataOutcome<Decimal> {
        if from == to {
            return DataOutcome(value: Sourced(1, metadata: DataMetadata(source: .computed, retrievedAt: clock.now(), delay: .endOfDay,
                                                                        quality: .validated)), failures: [])
        }
        let day = min(date, clock.today())
        if let hit = try? await cache.read({ try CacheRecords.rate(base: from, quote: to, onOrBefore: day, maxAgeDays: Self.maxAgeDays, in: $0) }) {
            return DataOutcome(value: Sourced(hit.0.rate, metadata: DataMetadata(source: DataSourceInfo(id: hit.sourceID, name: hit.sourceID),
                                                                                 retrievedAt: hit.retrievedAt,
                                                                                 marketTimestamp: hit.0.date.startOfDay(in: .current),
                                                                                 delay: hit.sourceID == DataSourceInfo.demo.id ? .synthetic : .cached,
                                                                                 quality: .validated)), failures: [])
        }
        var failures: [ProviderAttempt] = []
        for provider in ordered(from: from, to: to) {
            do {
                let result = try await provider.rates(base: from, quotes: [to], on: day)
                guard let rate = result.value.first(where: { $0.quote == to }) else { throw ProviderFailure.notFound }
                let toStore = [rate, rate.inverted]
                let source = result.metadata.source
                let retrieved = result.metadata.retrievedAt
                try? await cache.write { try CacheRecords.saveRates(toStore, source: source, retrievedAt: retrieved, in: $0) }
                return DataOutcome(value: Sourced(rate.rate, metadata: result.metadata), failures: failures)
            } catch {
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: error as? ProviderFailure ?? .connectionFailed))
            }
        }
        return DataOutcome(value: nil, failures: failures)
    }

    private func ordered(from: CurrencyCode, to: CurrencyCode) -> [any ExchangeRateProvider] {
        let preferredID = (from == .czk || to == .czk) ? CNBExchangeRateProvider.id : ECBExchangeRateProvider.id
        return providers.filter { $0.info.id == preferredID } + providers.filter { $0.info.id != preferredID }
    }
}
