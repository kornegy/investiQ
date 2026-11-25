import Foundation
import InvestiQCore
import InvestiQAnalytics

/// Price and FX inputs for a valuation, each with provenance.
public struct ValuationInputs: Sendable {
    /// Latest price per position (position currency).
    public var prices: [PositionKey: Sourced<Decimal>]
    /// Base units per one unit of each currency at the valuation date.
    public var fxToBase: [CurrencyCode: Sourced<Decimal>]

    public init(prices: [PositionKey: Sourced<Decimal>] = [:], fxToBase: [CurrencyCode: Sourced<Decimal>] = [:]) {
        self.prices = prices
        self.fxToBase = fxToBase
    }
}

public struct HoldingValuation: Sendable, Identifiable, Hashable {
    public var id: PositionKey { position.key }
    public var position: PositionState
    public var price: Sourced<Decimal>?
    public var marketValue: Decimal?
    public var marketValueBase: Decimal?
    public var unrealized: Decimal?
    public var unrealizedBase: Decimal?
    /// (price − average cost) × quantity, converted at the current rate (M-VAL-1).
    public var priceEffectBase: Decimal?
    /// cost basis × current rate − cost basis at historical rates (M-VAL-1).
    public var fxEffectBase: Decimal?
    public var weight: Double?
}

/// What the total-return percentage is measured against (shown in the UI for transparency).
public enum ReturnBasis: String, Sendable {
    /// Σ deposits − Σ withdrawals.
    case netContributions
    /// Σ purchase costs (portfolios that do not record deposits).
    case totalPurchases
}

public struct PortfolioValuation: Sendable {
    public var baseCurrency: CurrencyCode
    public var holdings: [HoldingValuation]
    public var cashBase: Decimal?
    public var holdingsValueBase: Decimal?
    /// Holdings + cash. `nil` when any required price or rate is missing (never silently partial).
    public var totalValueBase: Decimal?
    public var investedBase: Decimal?
    public var unrealizedBase: Decimal?
    public var realizedBase: Decimal?
    public var dividendsBase: Decimal?
    public var couponsBase: Decimal?
    public var interestBase: Decimal?
    public var feesBase: Decimal?
    public var taxesBase: Decimal?
    public var totalReturnBase: Decimal?
    public var totalReturnFraction: Double?
    public var returnBasis: ReturnBasis
    public var missingPrices: [PositionKey]
    public var missingRates: [CurrencyCode]
    public var oldestPriceTimestamp: Date?
    public var worstDelay: DelayStatus?
}

/// Values a ledger with current prices and rates (docs/FINANCIAL_METHODOLOGY.md §1 M-VAL-1).
public enum PortfolioValuer {
    static func sum(_ values: [Decimal?]) -> Decimal? {
        var total: Decimal = 0
        for value in values {
            guard let value else { return nil }
            total += value
        }
        return total
    }

    public static func value(_ ledger: LedgerResult, inputs: ValuationInputs) -> PortfolioValuation {
        let base = ledger.baseCurrency
        func rate(_ currency: CurrencyCode) -> Decimal? { currency == base ? 1 : inputs.fxToBase[currency]?.value }
        var holdings: [HoldingValuation] = []
        var missingPrices: [PositionKey] = []
        var missingRates = Set<CurrencyCode>()
        for position in ledger.openPositions {
            let price = inputs.prices[position.key]
            let fx = rate(position.key.currency)
            if price == nil { missingPrices.append(position.key) }
            if fx == nil { missingRates.insert(position.key.currency) }
            let marketValue = price.map { position.quantity * $0.value }
            let marketValueBase = marketValue.flatMap { value in fx.map { value * $0 } }
            let unrealized = marketValue.map { $0 - position.costBasis }
            let unrealizedBase: Decimal? = {
                guard let marketValueBase, let costBase = position.costBasisBase else { return nil }
                return marketValueBase - costBase
            }()
            let priceEffect: Decimal? = {
                guard let unrealized, let fx else { return nil }
                return unrealized * fx
            }()
            let fxEffect: Decimal? = {
                guard let fx, let costBase = position.costBasisBase else { return nil }
                return position.costBasis * fx - costBase
            }()
            holdings.append(HoldingValuation(position: position, price: price, marketValue: marketValue, marketValueBase: marketValueBase,
                                             unrealized: unrealized, unrealizedBase: unrealizedBase, priceEffectBase: priceEffect,
                                             fxEffectBase: fxEffect, weight: nil))
        }
        var cashValues: [Decimal?] = []
        for (currency, amount) in ledger.cash where amount != 0 {
            let fx = rate(currency)
            if fx == nil { missingRates.insert(currency) }
            cashValues.append(fx.map { amount * $0 })
        }
        let cashBase = sum(cashValues)
        let holdingsValueBase = sum(holdings.map(\.marketValueBase))
        // Cash is included only when the portfolio records deposits; otherwise negative "cash" is just
        // the purchase cost and would cancel the holdings (M-ACC-3).
        let totalValueBase: Decimal? = ledger.tracksCash ? sum([holdingsValueBase, cashBase]) : holdingsValueBase
        if let total = totalValueBase, total > 0 {
            for index in holdings.indices {
                holdings[index].weight = holdings[index].marketValueBase.map { ($0 / total).doubleValue }
            }
        }
        let positions = Array(ledger.positions.values)
        let realized = sum(positions.map(\.realizedBase))
        let dividends = sum(positions.map(\.dividendsBase))
        let coupons = sum(positions.map(\.couponsBase))
        let withholding = sum(positions.map(\.taxWithheldBase))
        let tradingFees = sum(positions.map(\.tradingFeesBase))
        let unrealized = sum(holdings.map(\.unrealizedBase))
        let fees = sum([tradingFees, ledger.standaloneFeesBase, ledger.fxConversionFeesBase])
        let taxes = sum([withholding, ledger.taxesBase])
        // Trading fees are already inside cost basis/realised P&L; only standalone/FX fees and taxes are deducted here.
        let totalReturn = sum([realized, unrealized, dividends, coupons, ledger.interestBase,
                               ledger.standaloneFeesBase.map { -$0 }, ledger.fxConversionFeesBase.map { -$0 }, taxes.map { -$0 }])
        let basis: ReturnBasis = ledger.tracksCash ? .netContributions : .totalPurchases
        let denominator = ledger.tracksCash ? ledger.netContributionsBase : ledger.totalPurchasesBase
        let fraction: Double? = {
            guard let totalReturn, let denominator, denominator > 0 else { return nil }
            return (totalReturn / denominator).doubleValue
        }()
        let invested = sum(holdings.map(\.position.costBasisBase))
        let timestamps = holdings.compactMap { $0.price?.metadata.marketTimestamp ?? $0.price?.metadata.retrievedAt }
        return PortfolioValuation(baseCurrency: base, holdings: holdings.sorted { ($0.marketValueBase ?? 0) > ($1.marketValueBase ?? 0) },
                                  cashBase: cashBase, holdingsValueBase: holdingsValueBase, totalValueBase: totalValueBase,
                                  investedBase: invested, unrealizedBase: unrealized, realizedBase: realized, dividendsBase: dividends,
                                  couponsBase: coupons, interestBase: ledger.interestBase, feesBase: fees, taxesBase: taxes,
                                  totalReturnBase: totalReturn, totalReturnFraction: fraction, returnBasis: basis,
                                  missingPrices: missingPrices, missingRates: missingRates.sorted(),
                                  oldestPriceTimestamp: timestamps.min(), worstDelay: worstDelay(holdings.compactMap { $0.price?.metadata.delay }))
    }

    static func worstDelay(_ delays: [DelayStatus]) -> DelayStatus? {
        func rank(_ delay: DelayStatus) -> Int {
            switch delay {
            case .realtime: return 0
            case .delayed: return 1
            case .endOfDay: return 2
            case .cached: return 3
            case .manual: return 4
            case .synthetic: return 5
            case .stale: return 6
            }
        }
        return delays.max { rank($0) < rank($1) }
    }
}

/// One point of the historical value series (base currency).
public struct ValuePoint: Sendable, Hashable {
    public var date: LocalDate
    public var value: Decimal?
    public var inflow: Decimal
    public var outflow: Decimal
}

/// Builds the portfolio value series from transactions + price history + FX history.
public enum ValueSeriesBuilder {
    /// Prices older than this many days are not carried forward (the point becomes missing).
    public static let maximumCarryDays = 7

    public static func build(transactions: [Transaction], baseCurrency: CurrencyCode, dates: [LocalDate],
                             prices: [PositionKey: PriceSeries], fx: (CurrencyCode, LocalDate) -> Decimal?,
                             rates: any HistoricalRateLookup = NoRateLookup()) -> [ValuePoint] {
        let ledger = PortfolioLedger(baseCurrency: baseCurrency, rates: rates)
        let splits = transactions.filter { $0.type == .split }
        guard let full = try? ledger.replay(transactions) else { return [] }
        let flowsByDate = Dictionary(full.flows.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        return dates.map { date in
            let flow = flowsByDate[date]
            guard let state = try? ledger.replay(transactions, upTo: date) else {
                return ValuePoint(date: date, value: nil, inflow: flow?.inflow ?? 0, outflow: flow?.outflow ?? 0)
            }
            var total: Decimal? = 0
            for position in state.openPositions {
                guard let series = prices[position.key], let bar = series.close(onOrBefore: date, maxCarryDays: maximumCarryDays),
                      let rate = position.key.currency == baseCurrency ? 1 : fx(position.key.currency, date) else {
                    total = nil
                    break
                }
                // Split-adjusted prices are on today's share basis: convert historical quantities to it.
                var quantity = position.quantity
                if series.adjustment != .unadjusted {
                    for split in splits where split.instrumentID == position.key.instrumentID && split.tradeDate > date {
                        quantity = quantity * Decimal(split.splitNumerator!) / Decimal(split.splitDenominator!)
                    }
                }
                total = total.map { $0 + quantity * bar.close * rate }
            }
            if state.tracksCash, var running = total {
                for (currency, amount) in state.cash where amount != 0 {
                    guard let rate = currency == baseCurrency ? 1 : fx(currency, date) else { total = nil; break }
                    running += amount * rate
                }
                if total != nil { total = running }
            }
            return ValuePoint(date: date, value: total, inflow: flow?.inflow ?? 0, outflow: flow?.outflow ?? 0)
        }
    }

    /// TWR over a value series; points with missing values are skipped (with the flows carried over).
    public static func timeWeightedReturn(_ points: [ValuePoint]) -> Double? {
        var compact: [TimeWeightedReturn.Point] = []
        var pendingIn = 0.0, pendingOut = 0.0
        for point in points {
            pendingIn += point.inflow.doubleValue
            pendingOut += point.outflow.doubleValue
            guard let value = point.value else { continue }
            compact.append(TimeWeightedReturn.Point(date: point.date, value: value.doubleValue, inflow: pendingIn, outflow: pendingOut))
            pendingIn = 0
            pendingOut = 0
        }
        return TimeWeightedReturn.compute(compact)
    }

    /// XIRR from the ledger's flows plus the terminal value (investor perspective).
    public static func moneyWeightedReturn(flows: [PortfolioFlow], terminalValue: Decimal?, terminalDate: LocalDate) -> Double? {
        guard let terminalValue else { return nil }
        var cashFlows = flows.flatMap { flow -> [XIRR.CashFlow] in
            [XIRR.CashFlow(date: flow.date, amount: -flow.inflow.doubleValue), XIRR.CashFlow(date: flow.date, amount: flow.outflow.doubleValue)]
        }
        cashFlows.append(XIRR.CashFlow(date: terminalDate, amount: terminalValue.doubleValue))
        return XIRR.solve(cashFlows)
    }
}
