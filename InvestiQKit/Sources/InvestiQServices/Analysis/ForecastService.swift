import Foundation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence
import InvestiQSecurity

public enum ForecastServiceError: Error, Equatable, Sendable {
    case noHistory
    case model(ForecastError)
}

public struct ModelAccuracy: Sendable, Equatable {
    public var modelID: String
    public var evaluated: Int
    public var pending: Int
    /// Mean absolute error as a fraction of the origin price.
    public var meanAbsolutePercentError: Double?
    /// Same, for the naive baseline on the same forecasts.
    public var naiveMeanAbsolutePercentError: Double?
    public var coverage80: Double?
    public var coverage95: Double?
    public var directionalAccuracy: Double?
}

/// Forecast ledger: forecasts are stored before their target date, never edited or deleted, and
/// evaluated against actual data later — failures included (spec §14).
public actor ForecastService {
    /// Inputs older than this many calendar days are stale (≈ 5 trading days).
    public static let staleAfterDays = 7

    private let store: DatabaseStore
    private let marketData: MarketDataService
    private let clock: any TimeProvider

    public init(store: DatabaseStore, marketData: MarketDataService, clock: any TimeProvider) {
        self.store = store
        self.marketData = marketData
        self.clock = clock
    }

    /// Target date `horizon` trading days (weekdays) after `origin`.
    static func targetDate(from origin: LocalDate, tradingDays: Int) -> LocalDate {
        var date = origin
        var remaining = tradingDays
        while remaining > 0 {
            date = date.adding(days: 1)
            if !date.isWeekend { remaining -= 1 }
        }
        return date
    }

    public func createForecast(instrumentID: InstrumentID, listing: Listing, model: ForecastModelID, horizon: Int,
                               allowStaleInput: Bool = false) async throws -> ForecastRow {
        let today = clock.today()
        guard let sourced = await marketData.history(for: listing, range: DateRange(start: today.adding(years: -10), end: today)).value,
              let last = sourced.value.lastDate else { throw ForecastServiceError.noHistory }
        let stale = last.days(to: today) > Self.staleAfterDays || sourced.metadata.delay == .stale
        if stale && !allowStaleInput { throw ForecastServiceError.model(.staleInput(lastObservation: last)) }
        let closes = sourced.value.bars.map { $0.close.doubleValue }
        let forecast: IntervalForecast
        do {
            forecast = try Forecaster().forecast(model, history: closes, originDate: last, horizon: horizon)
        } catch let error as ForecastError {
            throw ForecastServiceError.model(error)
        }
        let validation = WalkForwardValidator(horizon: horizon, step: max(horizon, 5)).validate(model, series: sourced.value)
        let hash = CryptoBox.sha256Hex(Data(closes.map { String($0) }.joined(separator: ",").utf8))
        let row = ForecastRow(instrumentID: instrumentID, listingKey: listing.key.description, modelID: model.rawValue,
                              modelVersion: ForecastModelID.version, createdAt: clock.now(), originDate: last,
                              targetDate: Self.targetDate(from: last, tradingDays: horizon), horizonDays: horizon, lastObservationDate: last,
                              originValue: forecast.originValue, point: forecast.point, lower80: forecast.lower80, upper80: forecast.upper80,
                              lower95: forecast.lower95, upper95: forecast.upper95, inputHash: hash, dataSource: sourced.metadata.source.id,
                              validationMASE: validation?.mase, staleInput: stale)
        try await store.write { try ForecastRecords.insert(row, in: $0) }
        return row
    }

    public func forecasts() async throws -> [ForecastRow] {
        try await store.read { try ForecastRecords.all(in: $0) }
    }

    /// Evaluates forecasts whose target date has passed and for which actual data exists.
    @discardableResult
    public func evaluateDueForecasts() async throws -> Int {
        let today = clock.today()
        let due = try await forecasts().filter { $0.evaluation == nil && $0.targetDate <= today }
        var evaluated = 0
        for forecast in due {
            let listings = try await store.read { try InstrumentRecords.listings(for: forecast.instrumentID, in: $0) }
            guard let listing = listings.first(where: { $0.key.description == forecast.listingKey }) else { continue }
            let range = DateRange(start: forecast.originDate, end: today)
            guard let series = await marketData.history(for: listing, range: range).value?.value,
                  let bar = series.close(onOrBefore: forecast.targetDate, maxCarryDays: 5), bar.date > forecast.originDate else { continue }
            let actual = bar.close.doubleValue
            let move = actual / forecast.originValue - 1
            let direction: Bool? = abs(move) < WalkForwardValidator.directionalDeadBand ? nil
                : (forecast.point - forecast.originValue).sign == (actual - forecast.originValue).sign
            let evaluation = ForecastEvaluationRow(evaluatedAt: clock.now(), actual: actual, absoluteError: abs(forecast.point - actual),
                                                   naiveAbsoluteError: abs(forecast.originValue - actual),
                                                   within80: actual >= forecast.lower80 && actual <= forecast.upper80,
                                                   within95: actual >= forecast.lower95 && actual <= forecast.upper95,
                                                   directionCorrect: direction)
            let id = forecast.id
            try await store.write { try ForecastRecords.insertEvaluation(evaluation, for: id, in: $0) }
            evaluated += 1
        }
        return evaluated
    }

    public func accuracy() async throws -> [ModelAccuracy] {
        let all = try await forecasts()
        return Dictionary(grouping: all, by: \.modelID).map { model, rows in
            let done = rows.filter { $0.evaluation != nil }
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            let directional = done.compactMap { $0.evaluation?.directionCorrect }
            return ModelAccuracy(modelID: model, evaluated: done.count, pending: rows.count - done.count,
                                 meanAbsolutePercentError: mean(done.map { $0.evaluation!.absoluteError / $0.originValue }),
                                 naiveMeanAbsolutePercentError: mean(done.map { $0.evaluation!.naiveAbsoluteError / $0.originValue }),
                                 coverage80: mean(done.map { $0.evaluation!.within80 ? 1 : 0 }),
                                 coverage95: mean(done.map { $0.evaluation!.within95 ? 1 : 0 }),
                                 directionalAccuracy: mean(directional.map { $0 ? 1 : 0 }))
        }
        .sorted { $0.modelID < $1.modelID }
    }
}
