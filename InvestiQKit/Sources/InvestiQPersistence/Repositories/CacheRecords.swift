import Foundation
import InvestiQCore

/// Public market data cached in the encrypted cache database (docs/DATABASE_SCHEMA.md §2).
public enum CacheRecords {
    public static func saveQuote(_ quote: Sourced<Quote>, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO market_quotes (listing_key, payload, market_timestamp, retrieved_at, source_id, source_name, delay, quality)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(listing_key) DO UPDATE SET payload = excluded.payload, market_timestamp = excluded.market_timestamp,
                retrieved_at = excluded.retrieved_at, source_id = excluded.source_id, source_name = excluded.source_name,
                delay = excluded.delay, quality = excluded.quality
            """, [.text(quote.value.listing.description), try .json(quote), .of(quote.metadata.marketTimestamp),
                  .of(quote.metadata.retrievedAt), .text(quote.metadata.source.id), .text(quote.metadata.source.name),
                  try .json(quote.metadata.delay), .of(quote.metadata.quality)])
    }

    public static func quote(_ listing: ListingKey, in db: SQLiteDatabase) throws -> Sourced<Quote>? {
        try db.queryOne("SELECT payload FROM market_quotes WHERE listing_key = ?", [.text(listing.description)])
            .map { try $0.json("payload") }
    }

    static func seriesKey(_ listing: ListingKey, _ adjustment: PriceAdjustment) -> String { "\(listing)|1d|\(adjustment.rawValue)" }

    public static func saveSeries(_ series: Sourced<PriceSeries>, in db: SQLiteDatabase) throws {
        let value = series.value
        try db.run("""
            INSERT INTO price_series (series_key, listing_key, interval, adjustment, currency, first_date, last_date, bar_count,
                payload, source_id, source_name, retrieved_at)
            VALUES (?, ?, '1d', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(series_key) DO UPDATE SET currency = excluded.currency, first_date = excluded.first_date,
                last_date = excluded.last_date, bar_count = excluded.bar_count, payload = excluded.payload,
                source_id = excluded.source_id, source_name = excluded.source_name, retrieved_at = excluded.retrieved_at
            """, [.text(seriesKey(value.listing, value.adjustment)), .text(value.listing.description), .of(value.adjustment),
                  .of(value.currency), .of(value.firstDate), .of(value.lastDate), .integer(Int64(value.bars.count)),
                  .blob(try JSONEncoder().encode(series)), .text(series.metadata.source.id), .text(series.metadata.source.name),
                  .of(series.metadata.retrievedAt)])
    }

    /// The most recently retrieved series for a listing (any adjustment unless specified).
    public static func series(_ listing: ListingKey, adjustment: PriceAdjustment? = nil, in db: SQLiteDatabase) throws -> Sourced<PriceSeries>? {
        let row: SQLRow?
        if let adjustment {
            row = try db.queryOne("SELECT payload FROM price_series WHERE series_key = ?", [.text(seriesKey(listing, adjustment))])
        } else {
            row = try db.queryOne("SELECT payload FROM price_series WHERE listing_key = ? ORDER BY retrieved_at DESC LIMIT 1",
                                  [.text(listing.description)])
        }
        return try row.map { try JSONDecoder().decode(Sourced<PriceSeries>.self, from: try $0.blob("payload")) }
    }

    public static func saveFundamentals(_ snapshot: Sourced<FundamentalsSnapshot>, for listing: ListingKey, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO fundamentals_snapshot (listing_key, payload, source_id, source_name, retrieved_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(listing_key) DO UPDATE SET payload = excluded.payload, source_id = excluded.source_id,
                source_name = excluded.source_name, retrieved_at = excluded.retrieved_at
            """, [.text(listing.description), try .json(snapshot), .text(snapshot.metadata.source.id),
                  .text(snapshot.metadata.source.name), .of(snapshot.metadata.retrievedAt)])
    }

    public static func fundamentals(_ listing: ListingKey, in db: SQLiteDatabase) throws -> Sourced<FundamentalsSnapshot>? {
        try db.queryOne("SELECT payload FROM fundamentals_snapshot WHERE listing_key = ?", [.text(listing.description)])
            .map { try $0.json("payload") }
    }

    public static func saveRates(_ rates: [ExchangeRate], source: DataSourceInfo, retrievedAt: Date, in db: SQLiteDatabase) throws {
        for rate in rates {
            try db.run("""
                INSERT OR REPLACE INTO exchange_rates (base, quote, rate_date, rate, source_id, retrieved_at) VALUES (?, ?, ?, ?, ?, ?)
                """, [.of(rate.base), .of(rate.quote), .of(rate.date), .of(rate.rate), .text(source.id), .of(retrievedAt)])
        }
    }

    /// Latest stored rate on or before `date`, at most `maxAgeDays` older (weekends/holidays).
    public static func rate(base: CurrencyCode, quote: CurrencyCode, onOrBefore date: LocalDate, maxAgeDays: Int,
                            in db: SQLiteDatabase) throws -> (ExchangeRate, sourceID: String, retrievedAt: Date)? {
        guard let row = try db.queryOne("""
            SELECT * FROM exchange_rates WHERE base = ? AND quote = ? AND rate_date <= ? AND rate_date >= ?
            ORDER BY rate_date DESC, retrieved_at DESC LIMIT 1
            """, [.of(base), .of(quote), .of(date), .of(date.adding(days: -maxAgeDays))]) else { return nil }
        return (ExchangeRate(base: base, quote: quote, rate: try row.decimal("rate"), date: try row.localDate("rate_date")),
                try row.string("source_id"), try row.instant("retrieved_at"))
    }

    public static func recordProviderOutcome(providerID: String, success: Bool, failureKind: String?, at date: Date,
                                             in db: SQLiteDatabase) throws {
        try db.run("INSERT OR IGNORE INTO provider_metadata (provider_id) VALUES (?)", [.text(providerID)])
        if success {
            try db.run("UPDATE provider_metadata SET last_success_at = ? WHERE provider_id = ?", [.of(date), .text(providerID)])
        } else {
            try db.run("UPDATE provider_metadata SET last_failure_at = ?, last_failure_kind = ? WHERE provider_id = ?",
                       [.of(date), .of(failureKind), .text(providerID)])
        }
    }

    public struct ProviderHealth: Sendable, Hashable {
        public var providerID: String
        public var lastSuccess: Date?
        public var lastFailure: Date?
        public var lastFailureKind: String?
    }

    public static func providerHealth(in db: SQLiteDatabase) throws -> [ProviderHealth] {
        try db.query("SELECT * FROM provider_metadata").map {
            ProviderHealth(providerID: try $0.string("provider_id"), lastSuccess: $0.optionalInstant("last_success_at"),
                           lastFailure: $0.optionalInstant("last_failure_at"), lastFailureKind: $0.optionalString("last_failure_kind"))
        }
    }

    /// Removes all cached market data, news and HTTP responses (user data is in another database).
    public static func clearAll(in db: SQLiteDatabase) throws {
        for table in ["market_quotes", "price_series", "fundamentals_snapshot", "financial_statements", "dividends", "corporate_actions",
                      "exchange_rates", "news_articles", "economic_events", "http_cache", "provider_metadata"] {
            try db.run("DELETE FROM \(table)")
        }
    }
}
