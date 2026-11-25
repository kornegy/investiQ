import Foundation
import InvestiQCore
import InvestiQPersistence

public struct ImportOutcome: Sendable, Equatable {
    public var imported: Int
    public var skippedDuplicates: Int
    public var createdInstruments: Int
}

extension PortfolioService {
    /// Imports previewed rows into a portfolio in one database transaction: either every new row is
    /// valid against the ledger and all are inserted, or nothing changes.
    public func importRows(_ rows: [TransactionCSV.ParsedRow], into portfolioID: PortfolioID, now: Date) async throws -> ImportOutcome {
        try await storeForImport.write { db in
            guard let portfolio = try PortfolioRecords.portfolio(portfolioID, in: db) else { throw PortfolioServiceError.portfolioNotFound }
            let known = try TransactionRecords.externalRefs(portfolio: portfolioID, in: db)
            var created = 0
            var duplicates = 0
            var newTransactions: [Transaction] = []
            for (offset, row) in rows.enumerated() {
                guard !known.contains(row.externalRef) else { duplicates += 1; continue }
                var instrumentID: InstrumentID?
                var listingID: ListingID?
                if row.needsInstrument || row.isin != nil || row.ticker != nil {
                    let resolved = try Self.resolveInstrument(row, in: db, now: now, created: &created)
                    instrumentID = resolved.0
                    listingID = resolved.1
                }
                newTransactions.append(Transaction(
                    portfolioID: portfolioID, type: row.type, instrumentID: instrumentID, listingID: listingID, tradeDate: row.date,
                    quantity: row.quantity, price: row.price, amount: row.amount, currency: row.currency, fees: row.fees,
                    feeCurrency: row.feeCurrency, taxWithheld: row.taxWithheld, accruedInterest: row.accruedInterest,
                    fxRateToBase: row.fxRateToBase, counterCurrency: row.counterCurrency, counterAmount: row.counterAmount,
                    splitNumerator: row.splitNumerator, splitDenominator: row.splitDenominator, notes: row.notes, source: .csvImport,
                    externalRef: row.externalRef, createdAt: now.addingTimeInterval(Double(offset) / 1000)))
            }
            let existing = try TransactionRecords.all(portfolio: portfolioID, in: db)
            do {
                _ = try PortfolioLedger(baseCurrency: portfolio.baseCurrency).replay(existing + newTransactions)
            } catch let error as LedgerError {
                throw PortfolioServiceError.ledger(error)
            }
            for transaction in newTransactions { try TransactionRecords.insert(transaction, in: db) }
            return ImportOutcome(imported: newTransactions.count, skippedDuplicates: duplicates, createdInstruments: created)
        }
    }

    static func resolveInstrument(_ row: TransactionCSV.ParsedRow, in db: SQLiteDatabase, now: Date,
                                  created: inout Int) throws -> (InstrumentID, ListingID?) {
        if let isin = row.isin, let instrument = try InstrumentRecords.instrument(isin: isin, in: db) {
            let listing = try InstrumentRecords.listings(for: instrument.id, in: db).first { $0.tradingCurrency == row.currency }
            return (instrument.id, listing?.id)
        }
        if let ticker = row.ticker, let listing = try InstrumentRecords.listing(mic: row.mic, ticker: ticker, in: db) {
            return (listing.instrumentID, listing.id)
        }
        let name = row.name ?? row.ticker?.rawValue ?? row.isin?.rawValue ?? "?"
        let instrument = Instrument(kind: row.kind ?? .stock, name: name, isin: row.isin, currency: row.currency, source: "csvImport",
                                    createdAt: now)
        try InstrumentRecords.upsert(instrument, in: db)
        created += 1
        var listingID: ListingID?
        if let ticker = row.ticker {
            let listing = Listing(instrumentID: instrument.id, mic: row.mic, ticker: ticker, tradingCurrency: row.currency, isPrimary: true)
            try InstrumentRecords.upsert(listing, in: db)
            listingID = listing.id
        }
        return (instrument.id, listingID)
    }

    public func exportCSV(_ portfolioID: PortfolioID) async throws -> String {
        try await storeForImport.read { db in
            let transactions = try TransactionRecords.all(portfolio: portfolioID, in: db)
            let ids = Set(transactions.compactMap(\.instrumentID))
            var instruments: [InstrumentID: Instrument] = [:]
            var listings: [InstrumentID: Listing] = [:]
            for id in ids {
                instruments[id] = try InstrumentRecords.instrument(id, in: db)
                listings[id] = try InstrumentRecords.listings(for: id, in: db).first
            }
            return TransactionCSV.export(transactions, instruments: instruments, listings: listings)
        }
    }
}
