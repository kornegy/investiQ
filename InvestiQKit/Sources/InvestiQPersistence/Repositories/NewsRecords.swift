import Foundation
import InvestiQCore

/// Processed news in the encrypted cache database (headline and short summary only).
public enum NewsRecords {
    public static func upsert(_ article: NewsArticle, fetchedAt: Date, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO news_articles (id, canonical_url, payload, published_at, cluster_id, fetched_at) VALUES (?, ?, ?, ?, NULL, ?)
            ON CONFLICT(canonical_url) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at
            """, [.text(article.id), .text(article.canonicalURL), try .json(article), .of(article.publishedAt), .of(fetchedAt)])
    }

    public static func recent(since: Date, limit: Int, in db: SQLiteDatabase) throws -> [NewsArticle] {
        try db.query("SELECT payload FROM news_articles WHERE published_at >= ? ORDER BY published_at DESC LIMIT ?",
                     [.of(since), .integer(Int64(limit))]).map { try $0.json("payload") }
    }

    /// News older than the retention window is removed (it is not part of the user's data).
    public static func purge(before date: Date, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM news_articles WHERE published_at < ?", [.of(date)])
    }
}
