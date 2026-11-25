import Foundation
import InvestiQCore
import InvestiQData
import InvestiQPersistence
import InvestiQSecurity

public enum PortfolioServiceError: Error, Equatable, Sendable {
    case portfolioNotFound
    case invalidName
    case ledger(LedgerError)
    case virtualOnly
    case realOnly
}

/// Everything the Overview/Portfolio screens need for one portfolio.
public struct PortfolioSnapshot: Sendable {
    public var portfolio: Portfolio
    public var ledger: LedgerResult
    public var valuation: PortfolioValuation
    public var instruments: [InstrumentID: Instrument]
    public var ledgerHash: String
    public var computedAt: Date
}

public struct PerformanceSeries: Sendable {
    public var points: [ValuePoint]
    public var timeWeightedReturn: Double?
    public var moneyWeightedReturn: Double?
    /// True when some points lack prices or rates (gaps are shown, never filled).
    public var hasGaps: Bool
}

/// Portfolio use cases: CRUD, transaction validation through ledger replay, valuation, performance.
public actor PortfolioService {
    private let store: DatabaseStore
    private let marketData: MarketDataService
    private let exchangeRates: ExchangeRateService
    private let clock: any TimeProvider

    /// Exposed to extensions in other files of this module.
    nonisolated var storeForImport: DatabaseStore { store }

    public init(store: DatabaseStore, marketData: MarketDataService, exchangeRates: ExchangeRateService, clock: any TimeProvider) {
        self.store = store
        self.marketData = marketData
        self.exchangeRates = exchangeRates
        self.clock = clock
    }

    // MARK: Portfolios

    public func portfolios(kind: PortfolioKind? = nil) async throws -> [Portfolio] {
        try await store.read { try PortfolioRecords.all(kind: kind, in: $0) }
    }

    public func createPortfolio(name: String, kind: PortfolioKind, baseCurrency: CurrencyCode) async throws -> Portfolio {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(trimmed.count) else { throw PortfolioServiceError.invalidName }
        let portfolio = Portfolio(name: trimmed, kind: kind, baseCurrency: baseCurrency, createdAt: clock.now())
        try await store.write { try PortfolioRecords.insert(portfolio, in: $0) }
        return portfolio
    }

    public func renamePortfolio(_ id: PortfolioID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(trimmed.count) else { throw PortfolioServiceError.invalidName }
        try await store.write { db in
            guard var portfolio = try PortfolioRecords.portfolio(id, in: db) else { throw PortfolioServiceError.portfolioNotFound }
            portfolio.name = trimmed
            try PortfolioRecords.update(portfolio, in: db)
        }
    }

    /// Deletes a portfolio and its transactions (user-confirmed in the UI).
    public func deletePortfolio(_ id: PortfolioID) async throws {
        try await store.write { try PortfolioRecords.delete(id, in: $0) }
    }

    // MARK: Transactions

    public func transactions(_ portfolio: PortfolioID) async throws -> [Transaction] {
        try await store.read { try TransactionRecords.all(portfolio: portfolio, in: $0) }
    }

    /// Inserts transactions after verifying that the resulting ledger is valid (no oversell,
    /// valid fields). Either all are inserted or none (single database transaction).
    public func add(_ newTransactions: [Transaction]) async throws {
        guard let portfolioID = newTransactions.first?.portfolioID else { return }
        try await store.write { db in
            guard let portfolio = try PortfolioRecords.portfolio(portfolioID, in: db) else { throw PortfolioServiceError.portfolioNotFound }
            if newTransactions.contains(where: { $0.source == .simulator }) && portfolio.kind != .virtual {
                throw PortfolioServiceError.virtualOnly
            }
            let existing = try TransactionRecords.all(portfolio: portfolioID, in: db)
            do {
                _ = try PortfolioLedger(baseCurrency: portfolio.baseCurrency).replay(existing + newTransactions)
            } catch let error as LedgerError {
                throw PortfolioServiceError.ledger(error)
            }
            for transaction in newTransactions { try TransactionRecords.insert(transaction, in: db) }
        }
    }

    public func update(_ transaction: Transaction) async throws {
        try await store.write { db in
            guard let portfolio = try PortfolioRecords.portfolio(transaction.portfolioID, in: db) else {
                throw PortfolioServiceError.portfolioNotFound
            }
            let others = try TransactionRecords.all(portfolio: transaction.portfolioID, in: db).filter { $0.id != transaction.id }
            do {
                _ = try PortfolioLedger(baseCurrency: portfolio.baseCurrency).replay(others + [transaction])
            } catch let error as LedgerError {
                throw PortfolioServiceError.ledger(error)
            }
            try TransactionRecords.update(transaction, in: db)
        }
    }

    /// Deleting a transaction is refused if it would make later sales invalid.
    public func delete(_ transaction: Transaction) async throws {
        try await store.write { db in
            guard let portfolio = try PortfolioRecords.portfolio(transaction.portfolioID, in: db) else {
                throw PortfolioServiceError.portfolioNotFound
            }
            let remaining = try TransactionRecords.all(portfolio: transaction.portfolioID, in: db).filter { $0.id != transaction.id }
            do {
                _ = try PortfolioLedger(baseCurrency: portfolio.baseCurrency).replay(remaining)
            } catch let error as LedgerError {
                throw PortfolioServiceError.ledger(error)
            }
            try TransactionRecords.delete(transaction.id, in: db)
        }
    }

    /// SHA-256 over the canonical transaction list; stored with cached snapshots so stale caches are detectable.
    public static func ledgerHash(_ transactions: [Transaction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(PortfolioLedger.ordered(transactions))) ?? Data()
        return CryptoBox.sha256Hex(data)
    }

    // MARK: Valuation

    public func snapshot(_ portfolioID: PortfolioID) async throws -> PortfolioSnapshot {
        let (portfolio, transactions, instruments, listings, bonds) = try await store.read {
            db -> (Portfolio, [Transaction], [Instrument], [Listing], [InstrumentID: BondDetails]) in
            guard let portfolio = try PortfolioRecords.portfolio(portfolioID, in: db) else { throw PortfolioServiceError.portfolioNotFound }
            let transactions = try TransactionRecords.all(portfolio: portfolioID, in: db)
            let ids = Set(transactions.compactMap(\.instrumentID))
            let instruments = try ids.compactMap { try InstrumentRecords.instrument($0, in: db) }
            let listings = try ids.flatMap { try InstrumentRecords.listings(for: $0, in: db) }
            return (portfolio, transactions, instruments, listings, try Self.bondTerms(for: instruments, in: db))
        }
        let base = portfolio.baseCurrency
        let ledger: LedgerResult
        do {
            ledger = try PortfolioLedger(baseCurrency: base, rates: try await historicalRates(for: transactions, base: base))
                .replay(transactions)
        } catch let error as LedgerError {
            throw PortfolioServiceError.ledger(error)
        }
        var inputs = ValuationInputs()
        for position in ledger.openPositions {
            // Prefer the listing traded in the position currency.
            let candidates = listings.filter { $0.instrumentID == position.key.instrumentID }
            guard let listing = candidates.first(where: { $0.tradingCurrency == position.key.currency }) ?? candidates.first,
                  listing.tradingCurrency == position.key.currency else { continue }
            if let quote = await marketData.quote(for: listing).value {
                let factor = bonds[position.key.instrumentID]?.quoteToUnitFactor ?? 1
                inputs.prices[position.key] = quote.map { $0.price * factor }
            }
        }
        let today = clock.today()
        let currencies = Set(ledger.openPositions.map(\.key.currency)).union(ledger.cash.filter { $0.value != 0 }.keys)
        for currency in currencies where currency != base {
            if let rate = await exchangeRates.rate(from: currency, to: base, on: today).value { inputs.fxToBase[currency] = rate }
        }
        let valuation = PortfolioValuer.value(ledger, inputs: inputs)
        return PortfolioSnapshot(portfolio: portfolio, ledger: ledger, valuation: valuation,
                                 instruments: Dictionary(uniqueKeysWithValues: instruments.map { ($0.id, $0) }),
                                 ledgerHash: Self.ledgerHash(transactions), computedAt: clock.now())
    }

    /// Bond terms of the bonds among `instruments` (their quotes are percent of face value).
    static func bondTerms(for instruments: [Instrument], in db: SQLiteDatabase) throws -> [InstrumentID: BondDetails] {
        var terms: [InstrumentID: BondDetails] = [:]
        for instrument in instruments where instrument.kind.isBond {
            terms[instrument.id] = try InstrumentRecords.bondDetails(for: instrument.id, in: db)
        }
        return terms
    }

    /// Rates for transactions without a stored rate, fetched once per (currency, date).
    private func historicalRates(for transactions: [Transaction], base: CurrencyCode) async throws -> TableRateLookup {
        var table: [String: Decimal] = [:]
        for transaction in transactions where transaction.fxRateToBase == nil {
            for currency in Set([transaction.currency, transaction.counterCurrency].compactMap { $0 }) where currency != base {
                let key = TableRateLookup.key(currency, base, transaction.tradeDate)
                if table[key] == nil, let rate = await exchangeRates.rate(from: currency, to: base, on: transaction.tradeDate).value {
                    table[key] = rate.value
                }
            }
        }
        return TableRateLookup(table: table)
    }

    // MARK: Performance

    /// Value series on sampled dates (daily up to 3 months, weekly up to 1 year, monthly beyond) so that
    /// charts stay light and FX lookups bounded (docs/ARCHITECTURE.md §6).
    public func performance(_ portfolioID: PortfolioID, from start: LocalDate?, to end: LocalDate) async throws -> PerformanceSeries {
        let (portfolio, transactions, listings, bonds) = try await store.read {
            db -> (Portfolio, [Transaction], [Listing], [InstrumentID: BondDetails]) in
            guard let portfolio = try PortfolioRecords.portfolio(portfolioID, in: db) else { throw PortfolioServiceError.portfolioNotFound }
            let transactions = try TransactionRecords.all(portfolio: portfolioID, in: db)
            let ids = Set(transactions.compactMap(\.instrumentID))
            let instruments = try ids.compactMap { try InstrumentRecords.instrument($0, in: db) }
            return (portfolio, transactions, try ids.flatMap { try InstrumentRecords.listings(for: $0, in: db) },
                    try Self.bondTerms(for: instruments, in: db))
        }
        guard let first = transactions.map(\.tradeDate).min() else {
            return PerformanceSeries(points: [], timeWeightedReturn: nil, moneyWeightedReturn: nil, hasGaps: false)
        }
        let rangeStart = max(start ?? first, first)
        let dates = Self.sampleDates(from: rangeStart, to: end, flowDates: Set(transactions.map(\.tradeDate)))
        let base = portfolio.baseCurrency
        let rates = try await historicalRates(for: transactions, base: base)
        let ledger = try PortfolioLedger(baseCurrency: base, rates: rates).replay(transactions)
        var prices: [PositionKey: PriceSeries] = [:]
        for key in Set(ledger.positions.keys) {
            guard let listing = listings.first(where: { $0.instrumentID == key.instrumentID && $0.tradingCurrency == key.currency }) else { continue }
            if let series = await marketData.history(for: listing, range: DateRange(start: rangeStart.adding(days: -10), end: end)).value {
                prices[key] = series.value.scaled(by: bonds[key.instrumentID]?.quoteToUnitFactor ?? 1)
            }
        }
        var fxTable: [String: Decimal] = [:]
        let currencies = Set(ledger.positions.keys.map(\.currency)).union(ledger.cash.keys).filter { $0 != base }
        for currency in currencies {
            for date in dates {
                if let rate = await exchangeRates.rate(from: currency, to: base, on: date).value {
                    fxTable[TableRateLookup.key(currency, base, date)] = rate.value
                }
            }
        }
        let lookup = TableRateLookup(table: fxTable.merging(rates.table) { a, _ in a })
        let points = ValueSeriesBuilder.build(transactions: transactions, baseCurrency: base, dates: dates, prices: prices,
                                              fx: { lookup.rate(from: $0, to: base, on: $1) }, rates: rates)
        // XIRR over a window starts from the value at the window start, treated as an inflow; that value
        // already contains the flows of the start day, so only later flows are added.
        var flowsForXIRR = ledger.flows.filter { $0.date >= rangeStart }
        if rangeStart > first, let startValue = points.first?.value {
            flowsForXIRR = [PortfolioFlow(date: rangeStart, inflow: startValue, outflow: 0)] + ledger.flows.filter { $0.date > rangeStart }
        }
        return PerformanceSeries(points: points, timeWeightedReturn: ValueSeriesBuilder.timeWeightedReturn(points),
                                 moneyWeightedReturn: ValueSeriesBuilder.moneyWeightedReturn(flows: flowsForXIRR,
                                                                                             terminalValue: points.last?.value,
                                                                                             terminalDate: end),
                                 hasGaps: points.contains { $0.value == nil })
    }

    static func sampleDates(from start: LocalDate, to end: LocalDate, flowDates: Set<LocalDate>) -> [LocalDate] {
        guard start <= end else { return [] }
        let span = start.days(to: end)
        let step = span <= 100 ? 1 : (span <= 400 ? 7 : 30)
        var dates: [LocalDate] = []
        var date = start
        while date < end {
            if !date.isWeekend || step > 1 { dates.append(date) }
            date = date.adding(days: step)
        }
        dates.append(end)
        // Flow dates are always included so TWR sub-periods break exactly at flows.
        return Array(Set(dates).union(flowDates.filter { $0 >= start && $0 <= end })).sorted()
    }
}

/// Rate lookup backed by a precomputed table (key "CCY>BASE@date").
public struct TableRateLookup: HistoricalRateLookup {
    let table: [String: Decimal]
    static func key(_ from: CurrencyCode, _ to: CurrencyCode, _ date: LocalDate) -> String { "\(from.rawValue)>\(to.rawValue)@\(date.iso)" }
    public func rate(from: CurrencyCode, to: CurrencyCode, on date: LocalDate) -> Decimal? {
        from == to ? 1 : table[Self.key(from, to, date)]
    }
}
