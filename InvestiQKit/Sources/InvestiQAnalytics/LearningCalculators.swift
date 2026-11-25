import Foundation

/// Calculators used in lessons. Educational arithmetic with user-chosen inputs, not forecasts.
public enum LearningCalculators {
    public struct YearValue: Sendable, Hashable, Identifiable {
        public var year: Int
        public var value: Double
        public var comparison: Double
        public var id: Int { year }
    }

    /// Purchasing power of `amount` after each year of constant `inflation` (comparison = nominal amount).
    public static func inflation(amount: Double, rate: Double, years: Int) -> [YearValue] {
        guard years > 0, rate > -1 else { return [] }
        return (0...years).map { YearValue(year: $0, value: amount / pow(1 + rate, Double($0)), comparison: amount) }
    }

    /// TER drag: `V0·((1+g)(1−fee))^t` (value) against `V0·(1+g)^t` (comparison) — FINANCIAL_METHODOLOGY §6.
    public static func feeDrag(amount: Double, grossReturn: Double, fee: Double, years: Int) -> [YearValue] {
        guard years > 0, fee >= 0, fee < 1, grossReturn > -1 else { return [] }
        return (0...years).map { year in
            YearValue(year: year, value: amount * pow((1 + grossReturn) * (1 - fee), Double(year)),
                      comparison: amount * pow(1 + grossReturn, Double(year)))
        }
    }

    /// Return in the home currency: `(1 + asset return)·(1 + change of the foreign currency) − 1`.
    public static func currencyAdjustedReturn(assetReturn: Double, currencyChange: Double) -> Double {
        (1 + assetReturn) * (1 + currencyChange) - 1
    }

    public struct DiversificationPoint: Sendable, Hashable, Identifiable {
        public var holdings: Int
        public var volatility: Double
        public var id: Int { holdings }
    }

    /// Equal-weight portfolio of `n` assets with the same volatility σ and pairwise correlation ρ:
    /// `σ_p = σ·√(1/n + (1 − 1/n)·ρ)`. The floor `σ·√ρ` is the risk diversification cannot remove.
    public static func diversification(volatility: Double, correlation: Double, maxHoldings: Int = 30) -> [DiversificationPoint] {
        guard volatility >= 0, (0...1).contains(correlation), maxHoldings >= 1 else { return [] }
        return (1...maxHoldings).map { n in
            let share = 1 / Double(n)
            return DiversificationPoint(holdings: n, volatility: volatility * (share + (1 - share) * correlation).squareRoot())
        }
    }
}
