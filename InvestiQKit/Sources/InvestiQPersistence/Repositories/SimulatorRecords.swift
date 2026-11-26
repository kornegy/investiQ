import Foundation
import InvestiQCore

/// Simulator sessions (one per virtual portfolio; a trigger rejects real portfolios).
public enum SimulatorRecords {
    public static func insert(_ session: SimulatorSession, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO simulator_sessions (portfolio_id, mode, start_date, sim_date, starting_capital, currency, fee_model, benchmark_instrument_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.of(session.portfolioID), .of(session.mode), .of(session.startDate), .of(session.simDate), .of(session.startingCapital),
                  .of(session.currency), try .json(session.feeModel), .of(session.benchmarkInstrumentID)])
    }

    public static func update(_ session: SimulatorSession, in db: SQLiteDatabase) throws {
        try db.run("""
            UPDATE simulator_sessions SET sim_date = ?, fee_model = ?, benchmark_instrument_id = ? WHERE portfolio_id = ?
            """, [.of(session.simDate), try .json(session.feeModel), .of(session.benchmarkInstrumentID), .of(session.portfolioID)])
    }

    public static func session(_ id: PortfolioID, in db: SQLiteDatabase) throws -> SimulatorSession? {
        try db.queryOne("SELECT * FROM simulator_sessions WHERE portfolio_id = ?", [.of(id)]).map(session(from:))
    }

    public static func all(in db: SQLiteDatabase) throws -> [SimulatorSession] {
        try db.query("SELECT * FROM simulator_sessions ORDER BY start_date DESC").map(session(from:))
    }

    static func session(from row: SQLRow) throws -> SimulatorSession {
        SimulatorSession(portfolioID: try row.id("portfolio_id"), mode: try row.enumValue("mode"), startDate: try row.localDate("start_date"),
                         simDate: try row.localDate("sim_date"), startingCapital: try row.decimal("starting_capital"),
                         currency: try row.currency("currency"), feeModel: try row.json("fee_model"),
                         benchmarkInstrumentID: row.optionalID("benchmark_instrument_id"))
    }
}
