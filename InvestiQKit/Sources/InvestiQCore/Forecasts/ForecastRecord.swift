import Foundation

/// A stored forecast (append-only ledger; enforced by triggers — docs/DATABASE_SCHEMA.md §1).
public struct ForecastRow: Sendable, Hashable, Identifiable, Codable {
    public var id: ForecastID
    public var instrumentID: InstrumentID
    public var listingKey: String
    public var modelID: String
    public var modelVersion: String
    public var createdAt: Date
    public var originDate: LocalDate
    public var targetDate: LocalDate
    public var horizonDays: Int
    public var lastObservationDate: LocalDate
    public var originValue: Double
    public var point: Double
    public var lower80: Double
    public var upper80: Double
    public var lower95: Double
    public var upper95: Double
    public var inputHash: String
    public var dataSource: String
    public var validationMASE: Double?
    public var staleInput: Bool
    public var evaluation: ForecastEvaluationRow?

    public init(id: ForecastID = ForecastID(), instrumentID: InstrumentID, listingKey: String, modelID: String, modelVersion: String,
                createdAt: Date, originDate: LocalDate, targetDate: LocalDate, horizonDays: Int, lastObservationDate: LocalDate,
                originValue: Double, point: Double, lower80: Double, upper80: Double, lower95: Double, upper95: Double,
                inputHash: String, dataSource: String, validationMASE: Double?, staleInput: Bool, evaluation: ForecastEvaluationRow? = nil) {
        self.id = id; self.instrumentID = instrumentID; self.listingKey = listingKey; self.modelID = modelID; self.modelVersion = modelVersion
        self.createdAt = createdAt; self.originDate = originDate; self.targetDate = targetDate; self.horizonDays = horizonDays
        self.lastObservationDate = lastObservationDate; self.originValue = originValue; self.point = point; self.lower80 = lower80
        self.upper80 = upper80; self.lower95 = lower95; self.upper95 = upper95; self.inputHash = inputHash; self.dataSource = dataSource
        self.validationMASE = validationMASE; self.staleInput = staleInput; self.evaluation = evaluation
    }
}

public struct ForecastEvaluationRow: Sendable, Hashable, Codable {
    public var evaluatedAt: Date
    public var actual: Double
    public var absoluteError: Double
    public var naiveAbsoluteError: Double
    public var within80: Bool
    public var within95: Bool
    public var directionCorrect: Bool?

    public init(evaluatedAt: Date, actual: Double, absoluteError: Double, naiveAbsoluteError: Double, within80: Bool, within95: Bool,
                directionCorrect: Bool?) {
        self.evaluatedAt = evaluatedAt; self.actual = actual; self.absoluteError = absoluteError; self.naiveAbsoluteError = naiveAbsoluteError
        self.within80 = within80; self.within95 = within95; self.directionCorrect = directionCorrect
    }
}

