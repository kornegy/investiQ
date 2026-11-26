import Foundation
import Observation
import InvestiQCore
import InvestiQData
import InvestiQServices

/// Market Explorer (spec §9): local library + provider search, filters, sorting, watchlist, comparison.
@MainActor
@Observable
public final class MarketExplorerViewModel {
    public enum SortOrder: String, CaseIterable, Sendable { case name, changeDescending, changeAscending, kind, marketCap }

    public var query = ""
    public var kindFilter: InstrumentKind?
    public var countryFilter: String?
    public var sectorFilter: String?
    public var currencyFilter: CurrencyCode?
    public var sortOrder: SortOrder = .name
    public var watchlistOnly = false
    public var compareSelection: [InstrumentID] = []
    public private(set) var library: [InstrumentEntry] = []
    public private(set) var remoteResults: [InstrumentSearchResult] = []
    public private(set) var quotes: [InstrumentID: DataOutcome<Quote>] = [:]
    public private(set) var marketCaps: [InstrumentID: Decimal] = [:]
    public private(set) var searchFailures: [ProviderAttempt] = []
    public private(set) var isSearching = false
    public private(set) var error: Message?

    public static let maximumComparison = 4
    private let app: AppModel
    private var searchTask: Task<Void, Never>?

    public init(app: AppModel) { self.app = app }

    private var services: SessionServices? { app.services }
    public var hasMarketProviders: Bool { !(services?.registry.marketData.isEmpty ?? true) }

    public func load() async {
        guard let services else { return }
        do {
            library = try await services.instruments.library()
        } catch {
            self.error = Message("market.error.libraryUnavailable")
            return
        }
        // Automatic quote refresh only for the watchlist (and everything in demo mode) to respect
        // free-plan quotas; other instruments refresh when opened (docs/DATA_PROVIDERS.md §1).
        let automatic = library.filter { $0.inWatchlist || services.mode == .demo }
        await withTaskGroup(of: (InstrumentID, DataOutcome<Quote>?).self) { group in
            for entry in automatic {
                guard let listing = entry.listing else { continue }
                group.addTask { (entry.id, await services.marketData.quote(for: listing)) }
            }
            for await (id, outcome) in group { if let outcome { quotes[id] = outcome } }
        }
        if services.mode == .demo {
            for entry in library where entry.instrument.kind == .stock {
                guard let listing = entry.listing else { continue }
                if let cap = await services.marketData.fundamentals(for: listing).value?.value.marketCapitalization { marketCaps[entry.id] = cap }
            }
        }
    }

    /// Distinct filter values present in the library.
    public var availableCountries: [String] { Array(Set(library.compactMap(\.instrument.country))).sorted() }
    public var availableSectors: [String] { Array(Set(library.compactMap(\.instrument.sector))).sorted() }
    public var availableCurrencies: [CurrencyCode] { Array(Set(library.map(\.instrument.currency))).sorted() }

    public var filteredLibrary: [InstrumentEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = library.filter { entry in
            let instrument = entry.instrument
            if watchlistOnly && !entry.inWatchlist { return false }
            if let kindFilter, instrument.kind != kindFilter { return false }
            if let countryFilter, instrument.country != countryFilter { return false }
            if let sectorFilter, instrument.sector != sectorFilter { return false }
            if let currencyFilter, instrument.currency != currencyFilter { return false }
            guard !needle.isEmpty else { return true }
            return instrument.name.lowercased().contains(needle)
                || entry.listing?.ticker.rawValue.lowercased().contains(needle) == true
                || instrument.isin?.rawValue.lowercased() == needle
        }
        return sorted(filtered)
    }

    private func change(_ entry: InstrumentEntry) -> Decimal? { quotes[entry.id]?.value?.value.changePercent }

    private func sorted(_ entries: [InstrumentEntry]) -> [InstrumentEntry] {
        switch sortOrder {
        case .name: return entries.sorted { $0.instrument.name.localizedCaseInsensitiveCompare($1.instrument.name) == .orderedAscending }
        case .kind: return entries.sorted { ($0.instrument.kind.rawValue, $0.instrument.name) < ($1.instrument.kind.rawValue, $1.instrument.name) }
        // Missing values sort last in both directions (never treated as zero).
        case .changeDescending: return entries.sorted { (change($0) ?? -.greatestFiniteMagnitude) > (change($1) ?? -.greatestFiniteMagnitude) }
        case .changeAscending: return entries.sorted { (change($0) ?? .greatestFiniteMagnitude) < (change($1) ?? .greatestFiniteMagnitude) }
        case .marketCap: return entries.sorted { (marketCaps[$0.id] ?? -1) > (marketCaps[$1.id] ?? -1) }
        }
    }

    /// Provider search is explicit (Return key) to conserve free-plan quotas.
    public func runRemoteSearch() {
        searchTask?.cancel()
        guard let services, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = query
        isSearching = true
        searchTask = Task {
            let outcome = await services.marketData.search(text)
            guard !Task.isCancelled else { return }
            let known = Set(library.compactMap { $0.instrument.isin?.rawValue })
            remoteResults = outcome.results.filter { $0.isin.map { !known.contains($0.rawValue) } ?? true }
            searchFailures = outcome.failures
            isSearching = false
        }
    }

    public func add(_ result: InstrumentSearchResult) async -> InstrumentEntry? {
        guard let services else { return nil }
        do {
            let entry = try await services.instruments.add(result)
            library = try await services.instruments.library()
            remoteResults.removeAll { $0.id == result.id }
            return entry
        } catch InstrumentServiceError.missingCurrency {
            error = Message("market.error.missingCurrency")
        } catch {
            self.error = Message("market.error.addFailed")
        }
        return nil
    }

    public func toggleWatchlist(_ id: InstrumentID) async {
        guard let services else { return }
        do {
            _ = try await services.instruments.toggleWatchlist(id)
            library = try await services.instruments.library()
        } catch {
            self.error = Message("market.error.watchlistFailed")
        }
    }

    public func toggleCompare(_ id: InstrumentID) {
        if let index = compareSelection.firstIndex(of: id) {
            compareSelection.remove(at: index)
        } else if compareSelection.count < Self.maximumComparison {
            compareSelection.append(id)
        }
    }

    public func clearFilters() {
        kindFilter = nil
        countryFilter = nil
        sectorFilter = nil
        currencyFilter = nil
        watchlistOnly = false
    }
}
