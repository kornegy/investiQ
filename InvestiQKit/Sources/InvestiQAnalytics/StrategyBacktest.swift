import Foundation
import InvestiQCore

/// Fixed-weight allocation back-test (M-SIM): monthly contributions, rebalancing rules and trading costs.
/// Statistics in Double behind the conversion boundary; results never flow into a ledger.
public struct StrategyBacktest: Sendable {
    public enum Rebalancing: String, Sendable, CaseIterable, Codable {
        case never, annually, quarterly
        /// When any weight drifts more than `driftThreshold` from its target (checked monthly).
        case threshold
    }

    public struct Asset: Sendable {
        public var key: String
        public var name: String
        public var targetWeight: Double
        public var series: PriceSeries
        public init(key: String, name: String, targetWeight: Double, series: PriceSeries) {
            self.key = key; self.name = name; self.targetWeight = targetWeight; self.series = series
        }
    }

    public struct Point: Sendable, Hashable, Identifiable {
        public var date: LocalDate
        public var value: Double
        public var contributed: Double
        public var id: LocalDate { date }
    }

    public struct Result: Sendable {
        public var points: [Point]
        public var finalValue: Double
        public var contributed: Double
        public var costs: Double
        public var rebalances: Int
        /// Time-weighted return over the whole period (contributions removed).
        public var timeWeightedReturn: Double?
        public var annualVolatility: Double?
        public var maxDrawdown: Double?
        public var finalWeights: [String: Double]
    }

    public enum BacktestError: Error, Equatable, Sendable {
        case weightsMustSumToOne
        case noPriceAtStart(String)
        case emptyPeriod
    }

    public static let driftThreshold = 0.05
    /// Prices are carried forward at most this many days; longer gaps hold the last value (flagged by `maxCarryDays`).
    public static let maxCarryDays = 7

    public let assets: [Asset]
    public let baseCurrency: CurrencyCode
    public let fees: FeeModel
    public let rebalancing: Rebalancing
    /// Base currency per unit of the asset currency on a date; must only use data up to that date.
    public let rate: @Sendable (CurrencyCode, LocalDate) -> Double?

    public init(assets: [Asset], baseCurrency: CurrencyCode, fees: FeeModel, rebalancing: Rebalancing,
                rate: @escaping @Sendable (CurrencyCode, LocalDate) -> Double?) {
        self.assets = assets; self.baseCurrency = baseCurrency; self.fees = fees; self.rebalancing = rebalancing; self.rate = rate
    }

    public func run(initial: Double, monthly: Double, from start: LocalDate, to end: LocalDate) throws -> Result {
        guard abs(assets.reduce(0) { $0 + $1.targetWeight } - 1) < 1e-6, assets.allSatisfy({ $0.targetWeight >= 0 }) else {
            throw BacktestError.weightsMustSumToOne
        }
        let dates = Set(assets.flatMap { $0.series.bars.map(\.date) }).filter { $0 >= start && $0 <= end }.sorted()
        guard let first = dates.first else { throw BacktestError.emptyPeriod }
        let spread = fees.spread.doubleValue / 2
        let percent = fees.percent.doubleValue, minimum = fees.minimum.doubleValue, fixed = fees.fixed.doubleValue
        let fxFee = fees.fxFee.doubleValue

        // Price in base currency on a date using only data up to that date (no look-ahead).
        func price(_ asset: Asset, _ date: LocalDate) -> Double? {
            guard let bar = asset.series.close(onOrBefore: date, maxCarryDays: Self.maxCarryDays) else { return nil }
            let fx = asset.series.currency == baseCurrency ? 1 : rate(asset.series.currency, date)
            return fx.map { bar.close.doubleValue * $0 }
        }
        func tradeCost(_ valueBase: Double, _ asset: Asset) -> Double {
            guard valueBase > 0 else { return 0 }
            let commission = max(minimum, fixed + percent * valueBase)
            let conversion = asset.series.currency == baseCurrency ? 0 : fxFee * valueBase
            return commission + conversion + spread * valueBase
        }

        var units = Array(repeating: 0.0, count: assets.count)
        var cash = 0.0, costs = 0.0, contributed = 0.0
        var rebalances = 0
        var points: [Point] = []
        var lastPrices = [Double?](repeating: nil, count: assets.count)

        /// Invests `amount` towards target weights (buys only).
        func invest(_ amount: Double, prices: [Double]) {
            for (index, asset) in assets.enumerated() where asset.targetWeight > 0 {
                let budget = amount * asset.targetWeight
                let cost = tradeCost(budget, asset)
                guard budget > cost else { continue }
                units[index] += (budget - cost) / prices[index]
                costs += cost
                cash -= budget
            }
        }
        func rebalance(prices: [Double]) {
            let total = cash + zip(units, prices).reduce(0) { $0 + $1.0 * $1.1 }
            for (index, asset) in assets.enumerated() {
                let difference = total * asset.targetWeight - units[index] * prices[index]
                guard abs(difference) > 1e-6 else { continue }
                let cost = tradeCost(abs(difference), asset)
                if difference > 0 {
                    units[index] += (difference - cost) / prices[index]
                    cash -= difference
                } else {
                    units[index] += difference / prices[index]
                    cash += -difference - cost
                }
                costs += cost
            }
            rebalances += 1
        }

        var previousMonth = first.month
        for date in dates {
            var prices: [Double] = []
            for (index, asset) in assets.enumerated() {
                if let p = price(asset, date) { lastPrices[index] = p; prices.append(p) }
                else if date == first { throw BacktestError.noPriceAtStart(asset.name) }
                else if let carried = lastPrices[index] { prices.append(carried) }
                else { throw BacktestError.noPriceAtStart(asset.name) }
            }
            if date == first {
                cash += initial
                contributed += initial
                invest(initial, prices: prices)
            } else if date.month != previousMonth {
                previousMonth = date.month
                if monthly > 0 {
                    cash += monthly
                    contributed += monthly
                    invest(monthly, prices: prices)
                }
                let total = cash + zip(units, prices).reduce(0) { $0 + $1.0 * $1.1 }
                let weights = zip(units, prices).map { total > 0 ? $0 * $1 / total : 0 }
                let drift = zip(weights, assets).contains { abs($0 - $1.targetWeight) > Self.driftThreshold }
                switch rebalancing {
                case .never: break
                case .annually: if date.month == first.month { rebalance(prices: prices) }
                case .quarterly: if (date.month - first.month + 12) % 3 == 0 { rebalance(prices: prices) }
                case .threshold: if drift { rebalance(prices: prices) }
                }
            }
            let value = cash + zip(units, prices).reduce(0) { $0 + $1.0 * $1.1 }
            points.append(Point(date: date, value: value, contributed: contributed))
        }
        // Time-weighted return: chain daily returns, removing contributions made on each day.
        var growth = 1.0
        var dailyReturns: [Double] = []
        for index in points.indices.dropFirst() {
            let flow = points[index].contributed - points[index - 1].contributed
            let previous = points[index - 1].value
            guard previous > 0 else { continue }
            let r = (points[index].value - flow) / previous - 1
            dailyReturns.append(r)
            growth *= 1 + r
        }
        var peak = 0.0, deepest = 0.0, wealth = 1.0
        for r in dailyReturns {
            wealth *= 1 + r
            peak = max(peak, wealth)
            deepest = max(deepest, 1 - wealth / peak)
        }
        let finalPrices = lastPrices.map { $0 ?? 0 }
        let finalValue = points.last?.value ?? 0
        var finalWeights: [String: Double] = [:]
        for (index, asset) in assets.enumerated() where finalValue > 0 {
            finalWeights[asset.key] = units[index] * finalPrices[index] / finalValue
        }
        let volatility = dailyReturns.count >= Performance.minimumReturns
            ? Statistics.standardDeviation(dailyReturns).map { $0 * Performance.tradingDaysPerYear.squareRoot() } : nil
        return Result(points: points, finalValue: finalValue, contributed: contributed, costs: costs, rebalances: rebalances,
                      timeWeightedReturn: dailyReturns.isEmpty ? nil : growth - 1, annualVolatility: volatility,
                      maxDrawdown: dailyReturns.isEmpty ? nil : deepest, finalWeights: finalWeights)
    }
}
