import Foundation
import InvestiQCore

public enum ForecastRecords {
    public static func insert(_ f: ForecastRow, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO forecasts (id, instrument_id, listing_key, model_id, model_version, created_at, origin_date, target_date, horizon_days,
                last_observation_date, origin_value, point, lower80, upper80, lower95, upper95, input_hash, data_source, validation_mase, stale_input)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.of(f.id), .of(f.instrumentID), .text(f.listingKey), .text(f.modelID), .text(f.modelVersion), .of(f.createdAt),
                  .of(f.originDate), .of(f.targetDate), .integer(Int64(f.horizonDays)), .of(f.lastObservationDate), .real(f.originValue),
                  .real(f.point), .real(f.lower80), .real(f.upper80), .real(f.lower95), .real(f.upper95), .text(f.inputHash),
                  .text(f.dataSource), .of(f.validationMASE), .of(f.staleInput)])
    }

    public static func insertEvaluation(_ e: ForecastEvaluationRow, for id: ForecastID, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO forecast_evaluations (forecast_id, evaluated_at, actual, abs_error, naive_abs_error, in80, in95, direction_correct)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.of(id), .of(e.evaluatedAt), .real(e.actual), .real(e.absoluteError), .real(e.naiveAbsoluteError), .of(e.within80),
                  .of(e.within95), e.directionCorrect.map { .of($0) } ?? .null])
    }

    public static func all(in db: SQLiteDatabase) throws -> [ForecastRow] {
        try db.query("""
            SELECT f.*, e.evaluated_at, e.actual, e.abs_error, e.naive_abs_error, e.in80, e.in95, e.direction_correct
            FROM forecasts f LEFT JOIN forecast_evaluations e ON e.forecast_id = f.id ORDER BY f.created_at DESC
            """).map { row in
            var evaluation: ForecastEvaluationRow?
            if let evaluatedAt = row.optionalInstant("evaluated_at"), let actual = row.optionalDouble("actual") {
                evaluation = ForecastEvaluationRow(evaluatedAt: evaluatedAt, actual: actual, absoluteError: row.optionalDouble("abs_error") ?? 0,
                                                   naiveAbsoluteError: row.optionalDouble("naive_abs_error") ?? 0,
                                                   within80: (row.optionalInt("in80") ?? 0) == 1, within95: (row.optionalInt("in95") ?? 0) == 1,
                                                   directionCorrect: row.optionalInt("direction_correct").map { $0 == 1 })
            }
            return ForecastRow(id: try row.id("id"), instrumentID: try row.id("instrument_id"), listingKey: try row.string("listing_key"),
                               modelID: try row.string("model_id"), modelVersion: try row.string("model_version"),
                               createdAt: try row.instant("created_at"), originDate: try row.localDate("origin_date"),
                               targetDate: try row.localDate("target_date"), horizonDays: try row.int("horizon_days"),
                               lastObservationDate: try row.localDate("last_observation_date"),
                               originValue: row.optionalDouble("origin_value") ?? 0, point: row.optionalDouble("point") ?? 0,
                               lower80: row.optionalDouble("lower80") ?? 0, upper80: row.optionalDouble("upper80") ?? 0,
                               lower95: row.optionalDouble("lower95") ?? 0, upper95: row.optionalDouble("upper95") ?? 0,
                               inputHash: try row.string("input_hash"), dataSource: try row.string("data_source"),
                               validationMASE: row.optionalDouble("validation_mase"), staleInput: try row.bool("stale_input"),
                               evaluation: evaluation)
        }
    }
}

public enum RiskRecords {
    public static func insert(portfolioID: PortfolioID, computedAt: Date, methodVersion: String, payloadJSON: SQLValue, in db: SQLiteDatabase) throws {
        try db.run("INSERT INTO risk_assessments (id, portfolio_id, computed_at, method_version, payload) VALUES (?, ?, ?, ?, ?)",
                   [.text(UUID().uuidString), .of(portfolioID), .of(computedAt), .text(methodVersion), payloadJSON])
    }

    public static func count(portfolioID: PortfolioID, in db: SQLiteDatabase) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM risk_assessments WHERE portfolio_id = ?", [.of(portfolioID)]) ?? 0)
    }
}
