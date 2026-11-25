import Foundation
import InvestiQCore

/// Historical performance statistics on price series (docs/FINANCIAL_METHODOLOGY.md §2–3).
public enum Performance {
    /// Trading days per year used for annualisation (M-VOL-1).
    public static let tradingDaysPerYear = 252.0
    /// Minimum daily returns for volatility/correlation (fewer → insufficient data).
    public static let minimumReturns = 60

    public static func closes(_ series: PriceSeries) -> [Double] { series.bars.map { $0.close.doubleValue } }

    public static func simpleReturns(_ prices: [Double]) -> [Double] {
        guard prices.count >= 2 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(prices.count - 1)
        for i in 1..<prices.count where prices[i - 1] > 0 {
            let ratio: Double = prices[i] / prices[i - 1]
            result.append(ratio - 1)
        }
        return result
    }

    public static func logReturns(_ prices: [Double]) -> [Double] {
        guard prices.count >= 2 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(prices.count - 1)
        for i in 1..<prices.count where prices[i - 1] > 0 && prices[i] > 0 {
            let ratio: Double = prices[i] / prices[i - 1]
            result.append(log(ratio))
        }
        return result
    }

    /// Total return between the first and last close.
    public static func totalReturn(_ series: PriceSeries) -> Double? {
        guard let first = series.bars.first?.close.doubleValue, let last = series.bars.last?.close.doubleValue, first > 0 else { return nil }
        return last / first - 1
    }

    /// CAGR = (P_end / P_start)^(365.25 / days) − 1; `nil` for periods shorter than one year
    /// (short periods are never annualised — docs/FINANCIAL_METHODOLOGY.md §2).
    public static func cagr(_ series: PriceSeries) -> Double? {
        guard let first = series.bars.first, let last = series.bars.last, first.close > 0 else { return nil }
        let days = Double(first.date.days(to: last.date))
        guard days >= 365 else { return nil }
        return pow(last.close.doubleValue / first.close.doubleValue, 365.25 / days) - 1
    }

    /// M-VOL-1: sample stdev of daily log returns × √252.
    public static func annualizedVolatility(_ series: PriceSeries) -> Double? {
        let returns = logReturns(closes(series))
        guard returns.count >= minimumReturns, let sd = Statistics.standardDeviation(returns) else { return nil }
        return sd * tradingDaysPerYear.squareRoot()
    }

    public struct Drawdown: Sendable, Equatable {
        /// Largest peak-to-trough fall as a positive fraction (0.35 = −35 %).
        public var depth: Double
        public var peak: LocalDate
        public var trough: LocalDate
        /// First date the previous peak was regained, if it was.
        public var recovery: LocalDate?
    }

    /// M-DD-1: max over t of 1 − P_t / max_{s≤t} P_s.
    public static func maximumDrawdown(_ series: PriceSeries) -> Drawdown? {
        guard series.bars.count >= 2 else { return nil }
        var peakValue = series.bars[0].close.doubleValue
        var peakDate = series.bars[0].date
        var worst: Drawdown?
        for bar in series.bars {
            let value = bar.close.doubleValue
            if value > peakValue {
                peakValue = value
                peakDate = bar.date
            }
            let depth = peakValue > 0 ? 1 - value / peakValue : 0
            if depth > (worst?.depth ?? 0) {
                worst = Drawdown(depth: depth, peak: peakDate, trough: bar.date, recovery: nil)
            }
        }
        guard var result = worst else { return Drawdown(depth: 0, peak: peakDate, trough: peakDate, recovery: nil) }
        let peakClose = series.bars.first { $0.date == result.peak }?.close ?? 0
        result.recovery = series.bars.first { $0.date > result.trough && $0.close >= peakClose }?.date
        return result
    }

    /// Explainable volatility result for the UI.
    public static func volatilityResult(_ series: Sourced<PriceSeries>, now: Date) -> AnalyticResult<Double> {
        let returns = logReturns(closes(series.value)).count
        let value = annualizedVolatility(series.value)
        var limitations = [Message("analytics.limitation.pastNotFuture")]
        if series.value.adjustment == .unadjusted { limitations.append(Message("analytics.limitation.unadjustedPrices")) }
        if returns < minimumReturns {
            limitations.append(Message("analytics.limitation.tooFewObservations", [.integer(returns), .integer(minimumReturns)]))
        }
        return AnalyticResult(methodID: "M-VOL-1", value: value,
                              inputs: [AnalyticInput(nameKey: "analytics.input.dailyReturns", value: String(returns))],
                              sources: [series.metadata.source], calculatedAt: now, limitations: limitations,
                              completeness: min(1, Double(returns) / Double(minimumReturns)),
                              explanation: value.map { Message("analytics.volatility.explanation", [.percent($0, fractionDigits: 1)]) })
    }

    public static func drawdownResult(_ series: Sourced<PriceSeries>, now: Date) -> AnalyticResult<Double> {
        let drawdown = maximumDrawdown(series.value)
        var limitations = [Message("analytics.limitation.pastNotFuture")]
        if series.value.adjustment == .unadjusted { limitations.append(Message("analytics.limitation.unadjustedPrices")) }
        let explanation = drawdown.map { d in
            d.recovery == nil
                ? Message("analytics.drawdown.explanationNotRecovered", [.percent(d.depth, fractionDigits: 1), .date(d.peak), .date(d.trough)])
                : Message("analytics.drawdown.explanation", [.percent(d.depth, fractionDigits: 1), .date(d.peak), .date(d.trough)])
        }
        return AnalyticResult(methodID: "M-DD-1", value: drawdown?.depth,
                              inputs: [AnalyticInput(nameKey: "analytics.input.observations", value: String(series.value.bars.count))],
                              sources: [series.metadata.source], calculatedAt: now, limitations: limitations,
                              completeness: series.value.bars.count >= 2 ? 1 : 0, explanation: explanation)
    }
}
