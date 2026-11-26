import Foundation
import InvestiQCore
import InvestiQData
import InvestiQPersistence

/// An instrument in the user's library with its primary listing.
public struct InstrumentEntry: Sendable, Hashable, Identifiable {
    public var instrument: Instrument
    public var listing: Listing?
    public var inWatchlist: Bool
    public var id: InstrumentID { instrument.id }
}

public enum InstrumentServiceError: Error, Equatable, Sendable {
    case missingTicker
    case missingCurrency
}

/// Manages instruments the user has added (from search, manual entry or the demo universe).
public actor InstrumentService {
    private let store: DatabaseStore
    private let clock: any TimeProvider

    public init(store: DatabaseStore, clock: any TimeProvider) {
        self.store = store
        self.clock = clock
    }

    public func library() async throws -> [InstrumentEntry] {
        let now = clock.now()
        return try await store.write { db in
            let watchlist = try WatchlistRecords.defaultWatchlist(in: db, now: now)
            return try InstrumentRecords.allInstruments(in: db).map { instrument in
                InstrumentEntry(instrument: instrument, listing: try InstrumentRecords.listings(for: instrument.id, in: db).first,
                                inWatchlist: watchlist.instrumentIDs.contains(instrument.id))
            }
        }
    }

    public func entry(_ id: InstrumentID) async throws -> InstrumentEntry? {
        let now = clock.now()
        return try await store.write { db in
            guard let instrument = try InstrumentRecords.instrument(id, in: db) else { return nil }
            let watchlist = try WatchlistRecords.defaultWatchlist(in: db, now: now)
            return InstrumentEntry(instrument: instrument, listing: try InstrumentRecords.listings(for: id, in: db).first,
                                   inWatchlist: watchlist.instrumentIDs.contains(id))
        }
    }

    /// Adds a search hit to the library. An existing instrument with the same ISIN or listing is reused,
    /// and the provider symbol is recorded on the listing.
    public func add(_ hit: InstrumentSearchResult) async throws -> InstrumentEntry {
        guard let ticker = hit.ticker ?? Ticker(rawValue: hit.symbol) else { throw InstrumentServiceError.missingTicker }
        guard let currency = hit.currency else { throw InstrumentServiceError.missingCurrency }
        let now = clock.now()
        return try await store.write { db in
            var instrument: Instrument
            if let isin = hit.isin, let existing = try InstrumentRecords.instrument(isin: isin, in: db) {
                instrument = existing
            } else if let listing = try InstrumentRecords.listing(mic: hit.mic, ticker: ticker, in: db),
                      let existing = try InstrumentRecords.instrument(listing.instrumentID, in: db) {
                instrument = existing
            } else {
                // Unknown kind defaults to stock; the user can change it (shown as provider-supplied data).
                instrument = Instrument(kind: hit.kind ?? .stock, name: hit.name, isin: hit.isin, country: hit.country,
                                        sector: hit.sector, currency: currency, source: hit.providerID, createdAt: now)
                try InstrumentRecords.upsert(instrument, in: db)
            }
            var listing = try InstrumentRecords.listing(mic: hit.mic, ticker: ticker, in: db)
                ?? Listing(instrumentID: instrument.id, mic: hit.mic, ticker: ticker, tradingCurrency: currency,
                           isPrimary: try InstrumentRecords.listings(for: instrument.id, in: db).isEmpty)
            listing.providerSymbols[hit.providerID] = hit.symbol
            try InstrumentRecords.upsert(listing, in: db)
            let watchlist = try WatchlistRecords.defaultWatchlist(in: db, now: now)
            return InstrumentEntry(instrument: instrument, listing: listing, inWatchlist: watchlist.instrumentIDs.contains(instrument.id))
        }
    }

    /// Adds or removes the instrument from the default watchlist; returns the new membership.
    @discardableResult
    public func toggleWatchlist(_ id: InstrumentID) async throws -> Bool {
        let now = clock.now()
        return try await store.write { db in
            let list = try WatchlistRecords.defaultWatchlist(in: db, now: now)
            if list.instrumentIDs.contains(id) {
                try WatchlistRecords.remove(id, from: list.id, in: db)
                return false
            }
            try WatchlistRecords.add(id, to: list.id, in: db, now: now)
            return true
        }
    }

    public func bondDetails(_ id: InstrumentID) async throws -> BondDetails? {
        try await store.read { try InstrumentRecords.bondDetails(for: id, in: $0) }
    }

    public func etfDetails(_ id: InstrumentID) async throws -> ETFDetails? {
        try await store.read { try InstrumentRecords.etfDetails(for: id, in: $0) }
    }

    public func saveBondDetails(_ bond: BondDetails, for id: InstrumentID) async throws {
        try await store.write { try InstrumentRecords.saveBondDetails(bond, for: id, in: $0) }
    }

    public func saveETFDetails(_ etf: ETFDetails, for id: InstrumentID) async throws {
        try await store.write { try InstrumentRecords.saveETFDetails(etf, for: id, in: $0) }
    }

    /// Inserts the synthetic demo universe into an (in-memory) demo database.
    public func seedDemoUniverse(watchlistCount: Int = 4) async throws {
        let now = clock.now()
        try await store.write { db in
            for demo in DemoUniverse.all {
                try InstrumentRecords.upsert(demo.instrument, in: db)
                var listing = demo.listing
                listing.providerSymbols[DemoDataProvider.id] = demo.listing.ticker.rawValue
                try InstrumentRecords.upsert(listing, in: db)
                if let bond = demo.bond { try InstrumentRecords.saveBondDetails(bond, for: demo.instrument.id, in: db) }
                if let etf = demo.etf { try InstrumentRecords.saveETFDetails(etf, for: demo.instrument.id, in: db) }
            }
            let list = try WatchlistRecords.defaultWatchlist(in: db, now: now)
            for demo in DemoUniverse.all.prefix(watchlistCount) { try WatchlistRecords.add(demo.instrument.id, to: list.id, in: db, now: now) }
        }
    }
}
