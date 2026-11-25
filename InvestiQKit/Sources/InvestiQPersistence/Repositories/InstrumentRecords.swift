import Foundation
import InvestiQCore

/// Instruments, listings and instrument details referenced by the user (user database).
public enum InstrumentRecords {
    public static func upsert(_ instrument: Instrument, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO instruments (id, kind, name, isin, figi, country, sector, issuer, currency, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name, isin = excluded.isin, figi = excluded.figi,
                country = excluded.country, sector = excluded.sector, issuer = excluded.issuer, currency = excluded.currency,
                updated_at = excluded.updated_at
            """, [.of(instrument.id), .of(instrument.kind), .text(instrument.name), .of(instrument.isin?.rawValue), .of(instrument.figi),
                  .of(instrument.country), .of(instrument.sector), .of(instrument.issuer), .of(instrument.currency),
                  .text(instrument.source), .of(instrument.createdAt), .of(instrument.updatedAt)])
    }

    public static func upsert(_ listing: Listing, in db: SQLiteDatabase) throws {
        if let mic = listing.mic {
            // Unknown venues get a minimal exchange row so the foreign key holds.
            try db.run("INSERT OR IGNORE INTO exchanges (mic, name, country, time_zone) VALUES (?, ?, '', 'UTC')",
                       [.text(mic.rawValue), .text(mic.rawValue)])
        }
        try db.run("""
            INSERT INTO listings (id, instrument_id, mic, ticker, trading_currency, is_primary, provider_symbols)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET mic = excluded.mic, ticker = excluded.ticker,
                trading_currency = excluded.trading_currency, is_primary = excluded.is_primary,
                provider_symbols = excluded.provider_symbols
            """, [.of(listing.id), .of(listing.instrumentID), .of(listing.mic?.rawValue), .text(listing.ticker.rawValue),
                  .of(listing.tradingCurrency), .of(listing.isPrimary), try .json(listing.providerSymbols)])
    }

    static func instrument(from row: SQLRow) throws -> Instrument {
        Instrument(id: try row.id("id"), kind: try row.enumValue("kind"), name: try row.string("name"),
                   isin: row.optionalString("isin").flatMap(ISIN.init(rawValue:)), figi: row.optionalString("figi"),
                   country: row.optionalString("country"), sector: row.optionalString("sector"), issuer: row.optionalString("issuer"),
                   currency: try row.currency("currency"), source: try row.string("source"),
                   createdAt: try row.instant("created_at"), updatedAt: try row.instant("updated_at"))
    }

    static func listing(from row: SQLRow) throws -> Listing {
        guard let ticker = Ticker(rawValue: try row.string("ticker")) else { throw SQLiteError.typeMismatch(column: "ticker") }
        return Listing(id: try row.id("id"), instrumentID: try row.id("instrument_id"),
                       mic: row.optionalString("mic").flatMap(MIC.init(rawValue:)), ticker: ticker,
                       tradingCurrency: try row.currency("trading_currency"), isPrimary: try row.bool("is_primary"),
                       providerSymbols: try row.json("provider_symbols"))
    }

    public static func instrument(_ id: InstrumentID, in db: SQLiteDatabase) throws -> Instrument? {
        try db.queryOne("SELECT * FROM instruments WHERE id = ?", [.of(id)]).map(instrument(from:))
    }

    public static func instrument(isin: ISIN, in db: SQLiteDatabase) throws -> Instrument? {
        try db.queryOne("SELECT * FROM instruments WHERE isin = ?", [.text(isin.rawValue)]).map(instrument(from:))
    }

    public static func allInstruments(in db: SQLiteDatabase) throws -> [Instrument] {
        try db.query("SELECT * FROM instruments ORDER BY name COLLATE NOCASE").map(instrument(from:))
    }

    public static func listings(for instrument: InstrumentID, in db: SQLiteDatabase) throws -> [Listing] {
        try db.query("SELECT * FROM listings WHERE instrument_id = ? ORDER BY is_primary DESC, ticker", [.of(instrument)]).map(listing(from:))
    }

    public static func listing(_ id: ListingID, in db: SQLiteDatabase) throws -> Listing? {
        try db.queryOne("SELECT * FROM listings WHERE id = ?", [.of(id)]).map(listing(from:))
    }

    public static func listing(mic: MIC?, ticker: Ticker, in db: SQLiteDatabase) throws -> Listing? {
        if let mic {
            return try db.queryOne("SELECT * FROM listings WHERE mic = ? AND ticker = ?", [.text(mic.rawValue), .text(ticker.rawValue)])
                .map(listing(from:))
        }
        return try db.queryOne("SELECT * FROM listings WHERE mic IS NULL AND ticker = ?", [.text(ticker.rawValue)]).map(listing(from:))
    }

    public static func saveBondDetails(_ bond: BondDetails, for id: InstrumentID, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO bond_details (instrument_id, issuer_type, face_value, coupon_rate, coupon_frequency, day_count, issue_date,
                first_coupon_date, maturity_date, call_schedule, credit_rating, rating_agency, rating_date, min_denomination, seniority)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(instrument_id) DO UPDATE SET issuer_type = excluded.issuer_type, face_value = excluded.face_value,
                coupon_rate = excluded.coupon_rate, coupon_frequency = excluded.coupon_frequency, day_count = excluded.day_count,
                issue_date = excluded.issue_date, first_coupon_date = excluded.first_coupon_date, maturity_date = excluded.maturity_date,
                call_schedule = excluded.call_schedule, credit_rating = excluded.credit_rating, rating_agency = excluded.rating_agency,
                rating_date = excluded.rating_date, min_denomination = excluded.min_denomination, seniority = excluded.seniority
            """, [.of(id), .of(bond.issuerType), .of(bond.faceValue), .of(bond.couponRate), .of(bond.couponFrequency),
                  .of(bond.dayCount), .of(bond.issueDate), .of(bond.firstCouponDate), .of(bond.maturityDate),
                  try .json(bond.callSchedule), .of(bond.creditRating), .of(bond.ratingAgency), .of(bond.ratingDate),
                  .of(bond.minimumDenomination), .of(bond.seniority)])
    }

    public static func bondDetails(for id: InstrumentID, in db: SQLiteDatabase) throws -> BondDetails? {
        guard let row = try db.queryOne("SELECT * FROM bond_details WHERE instrument_id = ?", [.of(id)]) else { return nil }
        return BondDetails(issuerType: try row.enumValue("issuer_type"), faceValue: try row.decimal("face_value"),
                           couponRate: try row.decimal("coupon_rate"), couponFrequency: try row.int("coupon_frequency"),
                           dayCount: try row.enumValue("day_count"), issueDate: try row.optionalLocalDate("issue_date"),
                           firstCouponDate: try row.optionalLocalDate("first_coupon_date"), maturityDate: try row.localDate("maturity_date"),
                           callSchedule: try row.json("call_schedule"), creditRating: row.optionalString("credit_rating"),
                           ratingAgency: row.optionalString("rating_agency"), ratingDate: try row.optionalLocalDate("rating_date"),
                           minimumDenomination: try row.optionalDecimal("min_denomination"), seniority: row.optionalString("seniority"))
    }

    public static func saveETFDetails(_ etf: ETFDetails, for id: InstrumentID, in db: SQLiteDatabase) throws {
        try db.run("INSERT INTO etf_details (instrument_id, payload) VALUES (?, ?) ON CONFLICT(instrument_id) DO UPDATE SET payload = excluded.payload",
                   [.of(id), try .json(etf)])
    }

    public static func etfDetails(for id: InstrumentID, in db: SQLiteDatabase) throws -> ETFDetails? {
        try db.queryOne("SELECT payload FROM etf_details WHERE instrument_id = ?", [.of(id)]).map { try $0.json("payload") }
    }
}

public enum WatchlistRecords {
    public static let defaultName = "Watchlist"

    /// Returns the default watchlist, creating it if necessary.
    public static func defaultWatchlist(in db: SQLiteDatabase, now: Date) throws -> Watchlist {
        if let row = try db.queryOne("SELECT * FROM watchlists ORDER BY created_at LIMIT 1") {
            return try watchlist(from: row, in: db)
        }
        let list = Watchlist(name: defaultName, createdAt: now)
        try db.run("INSERT INTO watchlists (id, name, created_at) VALUES (?, ?, ?)", [.of(list.id), .text(list.name), .of(now)])
        return list
    }

    static func watchlist(from row: SQLRow, in db: SQLiteDatabase) throws -> Watchlist {
        let id: WatchlistID = try row.id("id")
        let items = try db.query("SELECT instrument_id FROM watchlist_items WHERE watchlist_id = ? ORDER BY position, added_at", [.of(id)])
        return Watchlist(id: id, name: try row.string("name"), createdAt: try row.instant("created_at"),
                         instrumentIDs: try items.map { try $0.id("instrument_id") })
    }

    public static func add(_ instrument: InstrumentID, to list: WatchlistID, in db: SQLiteDatabase, now: Date) throws {
        let next = (try db.scalarInt("SELECT COALESCE(MAX(position), 0) + 1 FROM watchlist_items WHERE watchlist_id = ?", [.of(list)])) ?? 1
        try db.run("INSERT OR IGNORE INTO watchlist_items (watchlist_id, instrument_id, added_at, position) VALUES (?, ?, ?, ?)",
                   [.of(list), .of(instrument), .of(now), .integer(next)])
    }

    public static func remove(_ instrument: InstrumentID, from list: WatchlistID, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM watchlist_items WHERE watchlist_id = ? AND instrument_id = ?", [.of(list), .of(instrument)])
    }
}
