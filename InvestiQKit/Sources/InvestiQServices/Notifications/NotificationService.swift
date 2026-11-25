import Foundation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence

/// Evaluates notification rules while the app is running (spec §23). It never claims round-the-clock
/// monitoring: checks happen on launch, unlock and periodically while InvestiQ is open.
public actor NotificationService {
    /// Delivery-log entries older than this are removed.
    public static let logRetentionDays = 120
    /// A provider counts as failing when its last failure is newer than its last success and within this window.
    public static let outageWindow: TimeInterval = 6 * 3600

    private let userStore: DatabaseStore
    private let cacheStore: DatabaseStore
    private let registry: ProviderRegistry
    private let portfolios: PortfolioService
    private let instruments: InstrumentService
    private let marketData: MarketDataService
    private let calendar: CalendarService
    private let clock: any TimeProvider

    public init(userStore: DatabaseStore, cacheStore: DatabaseStore, registry: ProviderRegistry, portfolios: PortfolioService,
                instruments: InstrumentService, marketData: MarketDataService, calendar: CalendarService, clock: any TimeProvider) {
        self.userStore = userStore; self.cacheStore = cacheStore; self.registry = registry; self.portfolios = portfolios
        self.instruments = instruments; self.marketData = marketData; self.calendar = calendar; self.clock = clock
    }

    // MARK: Rules

    public func rules() async throws -> [NotificationRule] {
        let stored = try await userStore.read { try NotificationRecords.rules(in: $0) }
        let missing = NotificationRule.defaults(now: clock.now()).filter { rule in !stored.contains { $0.kind == rule.kind } }
        // Every kind is a member of allCases, so the index lookup cannot fail.
        func order(_ rule: NotificationRule) -> Int { NotificationKind.allCases.firstIndex(of: rule.kind) ?? 0 }
        return (stored + missing).sorted { order($0) < order($1) }
    }

    public func save(_ rule: NotificationRule) async throws {
        try await userStore.write { try NotificationRecords.save(rule, in: $0) }
    }

    // MARK: Evaluation

    /// Returns notifications not delivered before and records them as delivered.
    public func pendingNotifications() async throws -> [NotificationCandidate] {
        let rules = try await rules()
        guard rules.contains(where: \.enabled) else { return [] }
        let inputs = try await gatherInputs(rules: rules)
        let candidates = NotificationEvaluator.evaluate(inputs, rules: rules)
        let now = clock.now()
        let cutoff = now.addingTimeInterval(-Double(Self.logRetentionDays) * 86_400)
        return try await userStore.write { db in
            var fresh: [NotificationCandidate] = []
            for candidate in candidates where try !NotificationRecords.wasSent(candidate.dedupKey, in: db) {
                try NotificationRecords.logSent(candidate.dedupKey, kind: candidate.kind, at: now, in: db)
                fresh.append(candidate)
            }
            try NotificationRecords.purgeLog(before: cutoff, in: db)
            return fresh
        }
    }

    func gatherInputs(rules: [NotificationRule]) async throws -> NotificationEvaluator.Inputs {
        let today = clock.today()
        var inputs = NotificationEvaluator.Inputs(today: today)
        let library = try await instruments.library()
        var heldIDs = Set<InstrumentID>()
        for portfolio in try await portfolios.portfolios() {
            let snapshot = try await portfolios.snapshot(portfolio.id)
            let keys = snapshot.ledger.openPositions.map(\.key)
            heldIDs.formUnion(keys.map(\.instrumentID))
            let snapshots = try await userStore.read { try RiskRecords.latestLevels(portfolioID: portfolio.id, in: $0) }
            if snapshots.count == 2 {
                let (latest, previous) = (snapshots[0], snapshots[1])
                for (category, level) in latest.levels.sorted(by: { $0.key < $1.key }) {
                    guard let old = previous.levels[category], old != level, level != "unknown", old != "unknown" else { continue }
                    inputs.riskChanges.append(.init(portfolioName: portfolio.name, categoryKey: category, from: old, to: level,
                                                    computedAt: latest.computedAt))
                }
            }
        }
        let relevant = library.filter { heldIDs.contains($0.id) || $0.inWatchlist }
        let dividendProviders = registry.marketData.compactMap { $0 as? any DividendCalendarProvider }
        for entry in relevant {
            guard let listing = entry.listing else { continue }
            if let quote = await marketData.quote(for: listing).value {
                if quote.metadata.delay == .stale { inputs.staleInstruments.append(entry.instrument.name) }
                if let percent = quote.value.changePercent {
                    let date = quote.metadata.marketTimestamp.map { LocalDate($0, timeZone: TimeZone(identifier: "UTC") ?? .current) } ?? today
                    inputs.priceChanges.append(.init(instrumentID: entry.id, name: entry.instrument.name,
                                                     changeFraction: (percent / 100).doubleValue, date: date))
                }
            }
            if heldIDs.contains(entry.id) {
                if let bond = try await instruments.bondDetails(entry.id) {
                    inputs.maturities.append(.init(key: entry.id.string, name: entry.instrument.name, date: bond.maturityDate))
                    if let next = BondMath(terms: bond).couponDates().first(where: { $0 >= today }) {
                        inputs.coupons.append(.init(key: entry.id.string, name: entry.instrument.name, date: next))
                    }
                }
                for provider in dividendProviders {
                    guard let symbol = SymbolMapper.symbol(for: listing, providerID: provider.info.id) else { continue }
                    let upcoming = (try? await provider.upcomingDividends(symbol, range: DateRange(start: today, end: today.adding(days: 30)))) ?? []
                    for dividend in upcoming {
                        if let pay = dividend.payDate { inputs.dividends.append(.init(key: entry.id.string, name: entry.instrument.name, date: pay)) }
                    }
                    break
                }
            }
        }
        // Fetch as far ahead as the longest lead time of the enabled scheduled rules.
        let horizon = rules.filter { $0.enabled && [.earningsReport, .economicEvent].contains($0.kind) }
            .compactMap { $0.threshold.map { NSDecimalNumber(decimal: $0).intValue } }.max() ?? 0
        let outcome = try await calendar.upcoming(days: max(1, horizon))
        for event in outcome.events {
            switch event.kind {
            case .earningsReport:
                if let id = event.instrumentID, heldIDs.contains(id) || relevant.contains(where: { $0.id == id }) {
                    inputs.earnings.append(.init(key: id.string, name: event.institution, date: event.date))
                }
            case .centralBankDecision, .inflationRelease, .employmentReport:
                inputs.economicEvents.append((.init(key: event.id, name: event.institution, date: event.date),
                                              Message("calendar.title.\(event.kind.rawValue)", [.text(event.institution)])))
            case .other:
                continue
            }
        }
        let now = clock.now()
        let health = try await cacheStore.read { try CacheRecords.providerHealth(in: $0) }
        inputs.failingProviders = health.filter { item in
            guard let failure = item.lastFailure, now.timeIntervalSince(failure) <= Self.outageWindow else { return false }
            return item.lastSuccess.map { failure > $0 } ?? true
        }.map(\.providerID).sorted()
        return inputs
    }
}
