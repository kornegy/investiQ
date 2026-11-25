import Foundation

/// Migrations of the cache database (public, regenerable data — docs/DATABASE_SCHEMA.md §2).
public enum CacheSchema {
    public static let migrations: [Migration] = [v1]

    static let v1 = Migration(version: 1, name: "initial cache schema", sql: """
    CREATE TABLE market_quotes (
        listing_key TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        market_timestamp TEXT,
        retrieved_at TEXT NOT NULL,
        source_id TEXT NOT NULL,
        source_name TEXT NOT NULL,
        delay TEXT NOT NULL,
        quality TEXT NOT NULL
    );

    CREATE TABLE price_series (
        series_key TEXT PRIMARY KEY,
        listing_key TEXT NOT NULL,
        interval TEXT NOT NULL,
        adjustment TEXT NOT NULL CHECK (adjustment IN ('unadjusted','split','splitAndDividend')),
        currency TEXT NOT NULL,
        first_date TEXT,
        last_date TEXT,
        bar_count INTEGER NOT NULL,
        payload BLOB NOT NULL,
        source_id TEXT NOT NULL,
        source_name TEXT NOT NULL,
        retrieved_at TEXT NOT NULL
    );
    CREATE INDEX idx_price_series_listing ON price_series(listing_key);

    CREATE TABLE fundamentals_snapshot (
        listing_key TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        source_id TEXT NOT NULL,
        source_name TEXT NOT NULL,
        retrieved_at TEXT NOT NULL
    );

    CREATE TABLE financial_statements (
        listing_key TEXT NOT NULL,
        period TEXT NOT NULL CHECK (period IN ('annual','quarterly','ttm')),
        fiscal_date TEXT NOT NULL,
        payload TEXT NOT NULL,
        source_id TEXT NOT NULL,
        retrieved_at TEXT NOT NULL,
        PRIMARY KEY (listing_key, period, fiscal_date, source_id)
    );

    CREATE TABLE dividends (
        listing_key TEXT NOT NULL,
        ex_date TEXT NOT NULL,
        pay_date TEXT,
        amount TEXT NOT NULL,
        currency TEXT NOT NULL,
        source_id TEXT NOT NULL,
        PRIMARY KEY (listing_key, ex_date, source_id)
    );

    CREATE TABLE corporate_actions (
        listing_key TEXT NOT NULL,
        effective_date TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('split','reverseSplit','spinOff','merger','delisting')),
        ratio_numerator INTEGER,
        ratio_denominator INTEGER,
        source_id TEXT NOT NULL,
        retrieved_at TEXT NOT NULL,
        PRIMARY KEY (listing_key, effective_date, kind, source_id)
    );

    CREATE TABLE exchange_rates (
        base TEXT NOT NULL,
        quote TEXT NOT NULL,
        rate_date TEXT NOT NULL,
        rate TEXT NOT NULL,
        source_id TEXT NOT NULL,
        retrieved_at TEXT NOT NULL,
        PRIMARY KEY (base, quote, rate_date, source_id)
    );

    CREATE TABLE news_articles (
        id TEXT PRIMARY KEY,
        canonical_url TEXT NOT NULL UNIQUE,
        payload TEXT NOT NULL,
        published_at TEXT NOT NULL,
        cluster_id TEXT,
        fetched_at TEXT NOT NULL
    );
    CREATE INDEX idx_news_published ON news_articles(published_at);
    CREATE INDEX idx_news_cluster ON news_articles(cluster_id);

    CREATE TABLE economic_events (
        id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        scheduled_at TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('scheduled','rescheduled','released','cancelled')),
        source_id TEXT NOT NULL,
        retrieved_at TEXT NOT NULL
    );
    CREATE INDEX idx_events_scheduled ON economic_events(scheduled_at);

    CREATE TABLE brokers (
        id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        verified_at TEXT,
        dataset_version TEXT NOT NULL
    );

    CREATE TABLE provider_metadata (
        provider_id TEXT PRIMARY KEY,
        last_success_at TEXT,
        last_failure_at TEXT,
        last_failure_kind TEXT,
        requests_today INTEGER NOT NULL DEFAULT 0,
        day TEXT,
        rate_limited_until TEXT
    );

    CREATE TABLE http_cache (
        request_key TEXT PRIMARY KEY,
        body BLOB NOT NULL,
        etag TEXT,
        last_modified TEXT,
        stored_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
    );
    """)
}
