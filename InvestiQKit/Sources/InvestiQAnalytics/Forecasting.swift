import Foundation
import InvestiQCore

/// Statistical forecasting (docs/FINANCIAL_METHODOLOGY.md §8). No language model is involved.
public enum ForecastModelID: String, Sendable, CaseIterable, Codable {
    /// Random walk: tomorrow's best guess is today's price. The baseline every model must beat.
    case naive = "FC-NAIVE"
    /// Random walk with drift; log-normal intervals from historical volatility.
    case drift = "FC-DRIFT"
    /// Stationary block bootstrap of historical log returns (Monte Carlo, seeded).
    case bootstrap = "FC-BOOT"

    public static let version = "1"
}

public struct IntervalForecast: Sendable, Equatable, Codable {
    public var model: ForecastModelID
    public var originDate: LocalDate
    public var horizonDays: Int
    public var originValue: Double
    public var point: Double
    public var lower80: Double
    public var upper80: Double
    public var lower95: Double
    public var upper95: Double
}

public enum ForecastError: Error, Equatable, Sendable {
    case insufficientHistory(available: Int, required: Int)
    case staleInput(lastObservation: LocalDate)
}

public struct Forecaster: Sendable {
    /// Minimum daily observations used to fit a model (one trading year).
    public static let minimumTraining = 252
    public static let monteCarloPaths = 2_000
    public static let blockLength = 20

    public let seed: UInt64

    public init(seed: UInt64 = 42) { self.seed = seed }

    /// Forecast `horizon` trading days after the last observation of `history`. The caller must pass
    /// `series.asOf(origin)`; the model never sees later data (look-ahead protection).
    public func forecast(_ model: ForecastModelID, history: [Double], originDate: LocalDate, horizon: Int) throws -> IntervalForecast {
        guard history.count >= Self.minimumTraining, horizon > 0 else {
            throw ForecastError.insufficientHistory(available: history.count, required: Self.minimumTraining)
        }
        let last = history[history.count - 1]
        let returns = Performance.logReturns(history)
        let hReturns = Self.horizonReturns(history, horizon: horizon)
        func make(_ point: Double, _ q: (Double, Double, Double, Double)) -> IntervalForecast {
            IntervalForecast(model: model, originDate: originDate, horizonDays: horizon, originValue: last, point: point,
                             lower80: q.0, upper80: q.1, lower95: q.2, upper95: q.3)
        }
        switch model {
        case .naive:
            // Point = last price; interval from the empirical distribution of past h-day log returns.
            let q = Self.quantiles(hReturns.isEmpty ? [0] : hReturns)
            return make(last, (last * exp(q.p10), last * exp(q.p90), last * exp(q.p025), last * exp(q.p975)))
        case .drift:
            guard let mu = Statistics.mean(returns), let sigma = Statistics.standardDeviation(returns) else {
                throw ForecastError.insufficientHistory(available: history.count, required: Self.minimumTraining)
            }
            let h = Double(horizon)
            let center = log(last) + mu * h
            let spread = sigma * h.squareRoot()
            // z-scores of the standard normal: 1.2816 (80 % two-sided), 1.9600 (95 %).
            return make(exp(center), (exp(center - 1.2816 * spread), exp(center + 1.2816 * spread),
                                      exp(center - 1.96 * spread), exp(center + 1.96 * spread)))
        case .bootstrap:
            var generator = SeededRandom(seed: seed ^ UInt64(history.count) ^ UInt64(horizon) &* 31)
            var outcomes: [Double] = []
            outcomes.reserveCapacity(Self.monteCarloPaths)
            for _ in 0..<Self.monteCarloPaths {
                var total = 0.0
                var drawn = 0
                while drawn < horizon {
                    let start = Int(generator.next() % UInt64(max(1, returns.count - Self.blockLength)))
                    for offset in 0..<Self.blockLength where drawn < horizon && start + offset < returns.count {
                        total += returns[start + offset]
                        drawn += 1
                    }
                }
                outcomes.append(total)
            }
            let q = Self.quantiles(outcomes)
            return make(last * exp(q.p50), (last * exp(q.p10), last * exp(q.p90), last * exp(q.p025), last * exp(q.p975)))
        }
    }

    static func horizonReturns(_ prices: [Double], horizon: Int) -> [Double] {
        guard prices.count > horizon else { return [] }
        return (horizon..<prices.count).compactMap { i in
            prices[i - horizon] > 0 && prices[i] > 0 ? log(prices[i] / prices[i - horizon]) : nil
        }
    }

    struct Quantiles { var p025, p10, p50, p90, p975: Double }

    static func quantiles(_ values: [Double]) -> Quantiles {
        Quantiles(p025: Statistics.quantile(values, 0.025) ?? 0, p10: Statistics.quantile(values, 0.10) ?? 0,
                  p50: Statistics.quantile(values, 0.50) ?? 0, p90: Statistics.quantile(values, 0.90) ?? 0,
                  p975: Statistics.quantile(values, 0.975) ?? 0)
    }
}

/// Deterministic generator for Monte Carlo (SplitMix64); reproducible results for the same inputs.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Validation

public struct ValidationMetrics: Sendable, Equatable {
    public var model: ForecastModelID
    public var evaluations: Int
    public var mae: Double
    public var rmse: Double
    /// MAE relative to the in-sample naive h-step MAE (< 1 = better than naive).
    public var mase: Double?
    /// MAE relative to the naive forecast's MAE at the same origins (out of sample; naive = 1 by construction).
    public var relativeMAE: Double?
    public var directionalAccuracy: Double?
    public var coverage80: Double
    public var coverage95: Double
    /// Coverage at nominal levels 10 %, 20 % … 90 % (calibration curve) — only for interval models.
    public var calibration: [Double]

    /// Usefulness gate (FINANCIAL_METHODOLOGY §8): beats naive clearly and intervals are calibrated.
    public var isUsefulSignal: Bool {
        guard model != .naive, evaluations >= WalkForwardValidator.minimumEvaluations, let mase, let relativeMAE else { return false }
        return mase < WalkForwardValidator.maseThreshold && relativeMAE < WalkForwardValidator.maseThreshold
            && (0.70...0.90).contains(coverage80)
    }
}

public struct WalkForwardValidator: Sendable {
    public static let minimumEvaluations = 30
    public static let maseThreshold = 0.95
    /// Moves smaller than this are excluded from directional accuracy (noise).
    public static let directionalDeadBand = 0.001

    public let horizon: Int
    public let step: Int
    public let forecaster: Forecaster

    public init(horizon: Int = 21, step: Int = 21, forecaster: Forecaster = Forecaster()) {
        self.horizon = horizon
        self.step = step
        self.forecaster = forecaster
    }

    /// Expanding-window walk-forward evaluation. At each origin only data up to the origin is used.
    public func validate(_ model: ForecastModelID, series: PriceSeries) -> ValidationMetrics? {
        let bars = series.bars
        guard bars.count >= Forecaster.minimumTraining + horizon + 1 else { return nil }
        var errors: [Double] = [], squared: [Double] = [], naiveErrors: [Double] = [], naiveOutOfSample: [Double] = []
        var hits = 0, directional = 0, in80 = 0, in95 = 0
        var calibrationHits = Array(repeating: 0, count: 9)
        var count = 0
        var origin = Forecaster.minimumTraining - 1
        while origin + horizon < bars.count {
            let originDate = bars[origin].date
            // Look-ahead protection: the model only receives `asOf(originDate)`.
            let visible = series.asOf(originDate).bars.map { $0.close.doubleValue }
            guard let forecast = try? forecaster.forecast(model, history: visible, originDate: originDate, horizon: horizon) else {
                origin += step
                continue
            }
            let actual = bars[origin + horizon].close.doubleValue
            let error = abs(forecast.point - actual)
            errors.append(error)
            squared.append(error * error)
            naiveOutOfSample.append(abs(forecast.originValue - actual))
            // In-sample naive h-step MAE on the training window (MASE denominator).
            let train = visible
            if train.count > horizon {
                let naive = (horizon..<train.count).map { abs(train[$0] - train[$0 - horizon]) }
                naiveErrors.append(naive.reduce(0, +) / Double(naive.count))
            }
            let move = actual / forecast.originValue - 1
            if abs(move) >= Self.directionalDeadBand {
                directional += 1
                if (forecast.point - forecast.originValue).sign == (actual - forecast.originValue).sign { hits += 1 }
            }
            if actual >= forecast.lower80 && actual <= forecast.upper80 { in80 += 1 }
            if actual >= forecast.lower95 && actual <= forecast.upper95 { in95 += 1 }
            // Calibration: approximate nominal-level intervals by log-linear interpolation of the 80 %/95 % bands.
            for (index, level) in stride(from: 0.1, through: 0.9, by: 0.1).enumerated() {
                let (low, high) = Self.interval(forecast, level: level)
                if actual >= low && actual <= high { calibrationHits[index] += 1 }
            }
            count += 1
            origin += step
        }
        guard count > 0 else { return nil }
        let mae = errors.reduce(0, +) / Double(count)
        let scale = naiveErrors.isEmpty ? nil : naiveErrors.reduce(0, +) / Double(naiveErrors.count)
        return ValidationMetrics(model: model, evaluations: count, mae: mae, rmse: (squared.reduce(0, +) / Double(count)).squareRoot(),
                                 mase: scale.flatMap { $0 > 0 ? mae / $0 : nil },
                                 relativeMAE: Self.ratio(mae, naiveOutOfSample),
                                 directionalAccuracy: directional > 0 ? Double(hits) / Double(directional) : nil,
                                 coverage80: Double(in80) / Double(count), coverage95: Double(in95) / Double(count),
                                 calibration: calibrationHits.map { Double($0) / Double(count) })
    }

    /// `mae / mean(baseline)`, or `nil` when the baseline error is zero or missing.
    static func ratio(_ mae: Double, _ baseline: [Double]) -> Double? {
        guard !baseline.isEmpty else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        return mean > 0 ? mae / mean : nil
    }

    /// Interval at a nominal level assuming a symmetric log-normal shape fitted to the 80 % band.
    static func interval(_ forecast: IntervalForecast, level: Double) -> (Double, Double) {
        let z80 = 1.2816
        let zLevel = inverseNormal(0.5 + level / 2)
        let center = log(forecast.point)
        let halfWidth = (log(forecast.upper80) - log(forecast.lower80)) / 2 / z80 * zLevel
        return (exp(center - halfWidth), exp(center + halfWidth))
    }

    /// Acklam's rational approximation of the standard normal quantile (|error| < 1.2e-9).
    static func inverseNormal(_ p: Double) -> Double {
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 1 - low { return -inverseNormal(1 - p) }
        let q = p - 0.5, r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }
}

// MARK: - Scenarios and sensitivity

public struct ScenarioRange: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case pessimistic, base, optimistic }
    public var kind: Kind
    /// Total log-free return over the horizon (e.g. 0.12 = +12 %).
    public var periodReturn: Double
    public var endValue: Double
}

public enum ScenarioBuilder {
    /// Minimum history: three times the horizon, and at least three years.
    public static func requiredObservations(horizon: Int) -> Int { max(3 * horizon, 756) }

    /// Optimistic/base/pessimistic = 80th/50th/20th percentiles of historical rolling returns over the
    /// same horizon. No probability is attached to any scenario (spec §14).
    public static func scenarios(history: [Double], horizon: Int, startValue: Double) -> [ScenarioRange]? {
        guard history.count >= requiredObservations(horizon: horizon) else { return nil }
        let rolling = Forecaster.horizonReturns(history, horizon: horizon).map { exp($0) - 1 }
        guard let p20 = Statistics.quantile(rolling, 0.2), let p50 = Statistics.quantile(rolling, 0.5),
              let p80 = Statistics.quantile(rolling, 0.8) else { return nil }
        return [ScenarioRange(kind: .pessimistic, periodReturn: p20, endValue: startValue * (1 + p20)),
                ScenarioRange(kind: .base, periodReturn: p50, endValue: startValue * (1 + p50)),
                ScenarioRange(kind: .optimistic, periodReturn: p80, endValue: startValue * (1 + p80))]
    }

    public struct SensitivityCell: Sendable, Equatable {
        public var annualReturn: Double
        public var years: Int
        public var endValue: Double
    }

    /// Outcome grid for user-chosen amounts: return assumption ±2/±4 percentage points × horizons.
    public static func sensitivity(amount: Double, baseAnnualReturn: Double, horizons: [Int] = [1, 5, 10]) -> [SensitivityCell] {
        let shifts = [-0.04, -0.02, 0, 0.02, 0.04]
        return shifts.flatMap { shift in
            horizons.map { years in
                let rate = baseAnnualReturn + shift
                return SensitivityCell(annualReturn: rate, years: years, endValue: amount * pow(1 + rate, Double(years)))
            }
        }
    }
}
