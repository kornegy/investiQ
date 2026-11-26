import Foundation
import InvestiQCore

public enum OrderSide: String, Sendable, CaseIterable, Codable { case buy, sell }

/// Price and cost breakdown of a simulated order (M-SIM).
public struct OrderPreview: Sendable, Equatable {
    public var side: OrderSide
    public var quantity: Decimal
    public var referencePrice: Decimal
    /// Reference price ± half the spread.
    public var fillPrice: Decimal
    /// quantity × fill price, in the instrument currency.
    public var tradeValue: Decimal
    public var tradeCurrency: CurrencyCode
    /// Instrument currency → base currency (1 when equal).
    public var rateToBase: Decimal
    public var tradeValueBase: Decimal
    public var commissionBase: Decimal
    public var fxFeeBase: Decimal
    /// Spread cost compared with trading at the reference price (base currency, informational).
    public var spreadCostBase: Decimal
    /// Buy: total cash leaving the portfolio; sell: net cash received (base currency).
    public var netCashBase: Decimal
}

public enum SimulatorEngine {
    public static func preview(side: OrderSide, quantity: Decimal, referencePrice: Decimal, tradeCurrency: CurrencyCode,
                               baseCurrency: CurrencyCode, rateToBase: Decimal?, fees: FeeModel) -> OrderPreview? {
        guard quantity > 0, referencePrice > 0 else { return nil }
        let rate: Decimal
        if tradeCurrency == baseCurrency { rate = 1 } else if let rateToBase, rateToBase > 0 { rate = rateToBase } else { return nil }
        let halfSpread = fees.spread / 2
        let fill = (side == .buy ? referencePrice * (1 + halfSpread) : referencePrice * (1 - halfSpread)).rounded(scale: 4)
        let value = (quantity * fill).rounded(scale: 2)
        let valueBase = (value * rate).rounded(scale: 2)
        let commission = fees.commission(onBaseValue: valueBase)
        let fxFee = tradeCurrency == baseCurrency ? 0 : (valueBase * fees.fxFee).rounded(scale: 2)
        let spreadCost = (abs(fill - referencePrice) * quantity * rate).rounded(scale: 2)
        let net = side == .buy ? valueBase + commission + fxFee : valueBase - commission - fxFee
        return OrderPreview(side: side, quantity: quantity, referencePrice: referencePrice, fillPrice: fill, tradeValue: value,
                            tradeCurrency: tradeCurrency, rateToBase: rate, tradeValueBase: valueBase, commissionBase: commission,
                            fxFeeBase: fxFee, spreadCostBase: spreadCost, netCashBase: net)
    }
}

/// Patterns worth reflecting on (M-SIM mistake analysis). Educational observations, not judgements.
public enum SimulatorInsight: Sendable, Hashable {
    case highTurnover(annualRate: Double)
    case highFees(annualShareOfCapital: Double)
    case concentration(name: String, weight: Double)
    case sellingAfterFall(count: Int)
    case frequentTrading(tradesPerMonth: Double)
    case idleCash(share: Double)
}

public struct SimulatorTrade: Sendable, Hashable {
    public var date: LocalDate
    public var side: OrderSide
    public var instrumentKey: String
    public var valueBase: Decimal
    public var costsBase: Decimal
    public init(date: LocalDate, side: OrderSide, instrumentKey: String, valueBase: Decimal, costsBase: Decimal) {
        self.date = date; self.side = side; self.instrumentKey = instrumentKey; self.valueBase = valueBase; self.costsBase = costsBase
    }
}

public enum SimulatorReview {
    /// Thresholds (M-SIM): annual turnover above 100 %, costs above 1 % of capital a year, a single position
    /// above 20 %, more than 8 trades a month, idle cash above 50 % after the first month.
    public static let turnoverThreshold = 1.0
    public static let feeThreshold = 0.01
    public static let concentrationThreshold = 0.20
    public static let tradesPerMonthThreshold = 8.0
    public static let idleCashThreshold = 0.50
    /// A sale counts as "selling after a fall" when the close was ≥ 10 % below its 90-day high.
    public static let fallThreshold = 0.10
    public static let fallLookbackDays = 90
    /// Below this many trades, turnover and frequency statistics are not meaningful.
    public static let minimumTrades = 5

    public static func insights(trades: [SimulatorTrade], startingCapital: Decimal, start: LocalDate, end: LocalDate,
                                averageValueBase: Decimal?, weights: [(name: String, weight: Double)], cashShare: Double?,
                                histories: [String: PriceSeries]) -> [SimulatorInsight] {
        var result: [SimulatorInsight] = []
        let days = max(30, start.days(to: end))
        let years = Double(days) / 365
        if trades.count >= minimumTrades {
            let buys = trades.filter { $0.side == .buy }.reduce(Decimal(0)) { $0 + $1.valueBase }
            let sells = trades.filter { $0.side == .sell }.reduce(Decimal(0)) { $0 + $1.valueBase }
            if let average = averageValueBase, average > 0 {
                let turnover = min(buys, sells).doubleValue / average.doubleValue / years
                if turnover > turnoverThreshold { result.append(.highTurnover(annualRate: turnover)) }
            }
            let perMonth = Double(trades.count) / (Double(days) / 30.4375)
            if perMonth > tradesPerMonthThreshold { result.append(.frequentTrading(tradesPerMonth: perMonth)) }
        }
        let costs = trades.reduce(Decimal(0)) { $0 + $1.costsBase }
        if startingCapital > 0 {
            let share = costs.doubleValue / startingCapital.doubleValue / years
            if share > feeThreshold { result.append(.highFees(annualShareOfCapital: share)) }
        }
        for (name, weight) in weights where weight > concentrationThreshold {
            result.append(.concentration(name: name, weight: weight))
        }
        let fallSales = trades.filter { trade in
            guard trade.side == .sell, let series = histories[trade.instrumentKey] else { return false }
            let window = series.asOf(trade.date).bars.filter { $0.date >= trade.date.adding(days: -fallLookbackDays) }
            guard let last = window.last, let peak = window.map(\.close).max(), peak > 0 else { return false }
            return (1 - last.close / peak).doubleValue >= fallThreshold
        }.count
        if fallSales > 0 { result.append(.sellingAfterFall(count: fallSales)) }
        if let cashShare, cashShare > idleCashThreshold, days > 30 { result.append(.idleCash(share: cashShare)) }
        return result
    }
}

/// Benchmark with the same deposits and withdrawals (M-SIM): each flow buys or sells benchmark units at
/// that day's close with the same fee model; only data up to each date is used.
public enum BenchmarkReplay {
    public struct Flow: Sendable, Hashable {
        public var date: LocalDate
        /// Base-currency amount; positive = deposit.
        public var amountBase: Decimal
        public init(date: LocalDate, amountBase: Decimal) { self.date = date; self.amountBase = amountBase }
    }

    /// Value of the benchmark holding in the base currency on `end`; `nil` if a needed price or rate is missing.
    public static func value(flows: [Flow], series: PriceSeries, baseCurrency: CurrencyCode, end: LocalDate, fees: FeeModel,
                             rate: (CurrencyCode, LocalDate) -> Decimal?) -> Decimal? {
        var units: Decimal = 0
        for flow in flows.sorted(by: { $0.date < $1.date }) where flow.date <= end {
            guard let bar = series.close(onOrBefore: flow.date, maxCarryDays: 5) else { return nil }
            let fx: Decimal? = series.currency == baseCurrency ? 1 : rate(series.currency, flow.date)
            guard let fx else { return nil }
            let side: OrderSide = flow.amountBase >= 0 ? .buy : .sell
            let referenceBase = bar.close * fx
            guard referenceBase > 0 else { return nil }
            let roughQuantity = abs(flow.amountBase) / referenceBase
            guard let preview = SimulatorEngine.preview(side: side, quantity: roughQuantity, referencePrice: bar.close,
                                                        tradeCurrency: series.currency, baseCurrency: baseCurrency, rateToBase: fx,
                                                        fees: fees) else { continue }
            // Scale so that the cash moved after costs ≈ the flow (one linear step; the minimum commission makes
            // costs slightly non-linear, so the match is approximate to a fraction of the commission).
            guard preview.netCashBase > 0 else { continue }
            let quantity = roughQuantity * abs(flow.amountBase) / preview.netCashBase
            units += side == .buy ? quantity : -min(units, quantity)
        }
        guard let bar = series.close(onOrBefore: end, maxCarryDays: 5) else { return nil }
        let fx: Decimal? = series.currency == baseCurrency ? 1 : rate(series.currency, end)
        return fx.map { (units * bar.close * $0).rounded(scale: 2) }
    }
}
