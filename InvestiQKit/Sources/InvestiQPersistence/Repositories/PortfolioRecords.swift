import Foundation
import InvestiQCore

/// Portfolios and transactions (user database). Transactions are the single source of truth for
/// positions (ADR-016).
public enum PortfolioRecords {
    public static func insert(_ portfolio: Portfolio, in db: SQLiteDatabase) throws {
        try db.run("INSERT INTO portfolios (id, name, kind, base_currency, created_at, archived, notes) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [.of(portfolio.id), .text(portfolio.name), .of(portfolio.kind), .of(portfolio.baseCurrency), .of(portfolio.createdAt),
                    .of(portfolio.archived), .of(portfolio.notes)])
    }

    public static func update(_ portfolio: Portfolio, in db: SQLiteDatabase) throws {
        try db.run("UPDATE portfolios SET name = ?, archived = ?, notes = ? WHERE id = ?",
                   [.text(portfolio.name), .of(portfolio.archived), .of(portfolio.notes), .of(portfolio.id)])
    }

    public static func delete(_ id: PortfolioID, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM portfolios WHERE id = ?", [.of(id)])
    }

    static func portfolio(from row: SQLRow) throws -> Portfolio {
        Portfolio(id: try row.id("id"), name: try row.string("name"), kind: try row.enumValue("kind"),
                  baseCurrency: try row.currency("base_currency"), createdAt: try row.instant("created_at"),
                  archived: try row.bool("archived"), notes: row.optionalString("notes"))
    }

    public static func all(kind: PortfolioKind? = nil, in db: SQLiteDatabase) throws -> [Portfolio] {
        if let kind {
            return try db.query("SELECT * FROM portfolios WHERE kind = ? ORDER BY created_at", [.of(kind)]).map(portfolio(from:))
        }
        return try db.query("SELECT * FROM portfolios ORDER BY kind, created_at").map(portfolio(from:))
    }

    public static func portfolio(_ id: PortfolioID, in db: SQLiteDatabase) throws -> Portfolio? {
        try db.queryOne("SELECT * FROM portfolios WHERE id = ?", [.of(id)]).map(portfolio(from:))
    }
}

public enum TransactionRecords {
    public static func insert(_ t: Transaction, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO transactions (id, portfolio_id, type, instrument_id, listing_id, trade_date, settle_date, quantity, price, amount,
                currency, fees, fee_currency, tax_withheld, accrued_interest, fx_rate_to_base, counter_currency, counter_amount,
                split_numerator, split_denominator, notes, source, external_ref, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values(t))
    }

    public static func update(_ t: Transaction, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM transactions WHERE id = ?", [.of(t.id)])
        try insert(t, in: db)
    }

    public static func delete(_ id: TransactionID, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM transactions WHERE id = ?", [.of(id)])
    }

    static func values(_ t: Transaction) -> [SQLValue] {
        [.of(t.id), .of(t.portfolioID), .of(t.type), .of(t.instrumentID), .of(t.listingID), .of(t.tradeDate), .of(t.settleDate),
         .of(t.quantity), .of(t.price), .of(t.amount), .of(t.currency), .of(t.fees), .of(t.feeCurrency), .of(t.taxWithheld),
         .of(t.accruedInterest), .of(t.fxRateToBase), .of(t.counterCurrency), .of(t.counterAmount), .of(t.splitNumerator),
         .of(t.splitDenominator), .of(t.notes), .of(t.source), .of(t.externalRef), .of(t.createdAt)]
    }

    static func transaction(from row: SQLRow) throws -> Transaction {
        Transaction(id: try row.id("id"), portfolioID: try row.id("portfolio_id"), type: try row.enumValue("type"),
                    instrumentID: row.optionalID("instrument_id"), listingID: row.optionalID("listing_id"),
                    tradeDate: try row.localDate("trade_date"), settleDate: try row.optionalLocalDate("settle_date"),
                    quantity: try row.optionalDecimal("quantity"), price: try row.optionalDecimal("price"),
                    amount: try row.optionalDecimal("amount"), currency: try row.currency("currency"), fees: try row.decimal("fees"),
                    feeCurrency: row.optionalCurrency("fee_currency"), taxWithheld: try row.decimal("tax_withheld"),
                    accruedInterest: try row.optionalDecimal("accrued_interest"), fxRateToBase: try row.optionalDecimal("fx_rate_to_base"),
                    counterCurrency: row.optionalCurrency("counter_currency"), counterAmount: try row.optionalDecimal("counter_amount"),
                    splitNumerator: row.optionalInt("split_numerator"), splitDenominator: row.optionalInt("split_denominator"),
                    notes: row.optionalString("notes"), source: try row.enumValue("source"), externalRef: row.optionalString("external_ref"),
                    createdAt: try row.instant("created_at"))
    }

    public static func all(portfolio: PortfolioID, in db: SQLiteDatabase) throws -> [Transaction] {
        try db.query("SELECT * FROM transactions WHERE portfolio_id = ? ORDER BY trade_date, created_at", [.of(portfolio)])
            .map(transaction(from:))
    }

    public static func externalRefs(portfolio: PortfolioID, in db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT external_ref FROM transactions WHERE portfolio_id = ? AND external_ref IS NOT NULL", [.of(portfolio)])
            .compactMap { $0.optionalString("external_ref") })
    }
}
