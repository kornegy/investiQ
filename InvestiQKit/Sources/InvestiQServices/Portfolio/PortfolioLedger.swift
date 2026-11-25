import Foundation
import InvestiQCore

/// Positions are tracked per instrument *and* currency, because average cost across currencies is
/// meaningless (the same share bought in EUR on Xetra and in USD on NYSE stays two cost pools).
public struct PositionKey: Hashable, Sendable, Codable, Comparable {
    public var instrumentID: InstrumentID
    public var currency: CurrencyCode
    public init(instrumentID: InstrumentID, currency: CurrencyCode) { self.instrumentID = instrumentID; self.currency = currency }
    public static func < (lhs: PositionKey, rhs: PositionKey) -> Bool {
        (lhs.instrumentID.string, lhs.currency.rawValue) < (rhs.instrumentID.string, rhs.currency.rawValue)
    }
}

/// Accounting state of one position (docs/FINANCIAL_METHODOLOGY.md §1, M-ACC-1).
/// Instrument-currency values are exact; base-currency values are `nil` when an FX rate was missing.
public struct PositionState: Sendable, Hashable {
    public var key: PositionKey
    public var quantity: Decimal = 0
    /// Remaining cost basis in the position currency (purchase amounts + capitalised fees).
    public var costBasis: Decimal = 0
    /// Remaining cost basis in the base currency at historical FX rates.
    public var costBasisBase: Decimal? = 0
    public var realized: Decimal = 0
    public var realizedBase: Decimal? = 0
    public var dividends: Decimal = 0
    public var dividendsBase: Decimal? = 0
    public var coupons: Decimal = 0
    public var couponsBase: Decimal? = 0
    public var taxWithheld: Decimal = 0
    public var taxWithheldBase: Decimal? = 0
    public var tradingFees: Decimal = 0
    public var tradingFeesBase: Decimal? = 0
    public var accruedInterestPaid: Decimal = 0
    public var accruedInterestReceived: Decimal = 0
    public var firstAcquired: LocalDate?

    public init(key: PositionKey) { self.key = key }

    public var averageCost: Decimal? { quantity > 0 ? costBasis / quantity : nil }
    public var averageCostBase: Decimal? { quantity > 0 ? costBasisBase.map { $0 / quantity } : nil }
    public var isOpen: Bool { quantity > 0 }
}

public enum LedgerWarning: Hashable, Sendable {
    /// More money left a cash balance than was recorded as entering it (deposits probably missing).
    case negativeCash(CurrencyCode, LocalDate)
    case missingExchangeRate(CurrencyCode, LocalDate)
}

public enum LedgerError: Error, Equatable, Sendable {
    case invalidTransaction(TransactionID, TransactionValidationError)
    case insufficientQuantity(TransactionID, available: Decimal, requested: Decimal)
    case noPosition(TransactionID)
}

/// Supplies exchange rates for dates without a stored rate on the transaction (base per 1 unit).
public protocol HistoricalRateLookup: Sendable {
    func rate(from: CurrencyCode, to: CurrencyCode, on date: LocalDate) -> Decimal?
}

public struct NoRateLookup: HistoricalRateLookup {
    public init() {}
    public func rate(from: CurrencyCode, to: CurrencyCode, on date: LocalDate) -> Decimal? { from == to ? 1 : nil }
}

/// An external or inferred cash flow used for TWR/XIRR (base currency).
public struct PortfolioFlow: Sendable, Hashable {
    public var date: LocalDate
    /// Money entering the portfolio (deposit, or purchase cost when deposits are not tracked).
    public var inflow: Decimal
    /// Money leaving the portfolio (withdrawal, or sale proceeds/income when deposits are not tracked).
    public var outflow: Decimal
}

public struct LedgerResult: Sendable {
    public var baseCurrency: CurrencyCode
    public var positions: [PositionKey: PositionState]
    public var cash: [CurrencyCode: Decimal]
    /// Σ deposits − Σ withdrawals in the base currency (deposits are never profit, M-ACC-3).
    public var netContributionsBase: Decimal?
    public var totalPurchasesBase: Decimal?
    public var interestBase: Decimal?
    public var standaloneFeesBase: Decimal?
    public var taxesBase: Decimal?
    public var fxConversionFeesBase: Decimal?
    /// True when the portfolio records deposits/withdrawals; otherwise flows are inferred from trades.
    public var tracksCash: Bool
    public var flows: [PortfolioFlow]
    public var warnings: [LedgerWarning]
    public var transactionCount: Int

    public var openPositions: [PositionState] { positions.values.filter(\.isOpen).sorted { $0.key < $1.key } }
}

/// Replays transactions into positions, cash and income (single source of truth: ADR-016).
public struct PortfolioLedger: Sendable {
    public let baseCurrency: CurrencyCode
    public let rates: any HistoricalRateLookup

    public init(baseCurrency: CurrencyCode, rates: any HistoricalRateLookup = NoRateLookup()) {
        self.baseCurrency = baseCurrency
        self.rates = rates
    }

    /// Deterministic processing order (docs/FINANCIAL_METHODOLOGY.md §1).
    public static func ordered(_ transactions: [Transaction]) -> [Transaction] {
        transactions.sorted {
            ($0.tradeDate, $0.type.sameDayOrder, $0.createdAt, $0.id.string) < ($1.tradeDate, $1.type.sameDayOrder, $1.createdAt, $1.id.string)
        }
    }

    public func replay(_ transactions: [Transaction], upTo cutoff: LocalDate? = nil) throws -> LedgerResult {
        let tracksCash = transactions.contains { $0.type.isExternalFlow }
        var state = LedgerResult(baseCurrency: baseCurrency, positions: [:], cash: [:], netContributionsBase: 0, totalPurchasesBase: 0,
                                 interestBase: 0, standaloneFeesBase: 0, taxesBase: 0, fxConversionFeesBase: 0, tracksCash: tracksCash,
                                 flows: [], warnings: [], transactionCount: 0)
        for transaction in Self.ordered(transactions) {
            if let cutoff, transaction.tradeDate > cutoff { break }
            do {
                try TransactionValidator.validate(transaction, baseCurrency: baseCurrency)
            } catch let error as TransactionValidationError {
                throw LedgerError.invalidTransaction(transaction.id, error)
            }
            try apply(transaction, to: &state)
            state.transactionCount += 1
        }
        return state
    }

    /// Base units per one unit of `currency` for this transaction (stored rate preferred).
    private func fx(_ t: Transaction, _ currency: CurrencyCode, _ state: inout LedgerResult) -> Decimal? {
        if currency == baseCurrency { return 1 }
        if currency == t.currency, let stored = t.fxRateToBase { return stored }
        if let looked = rates.rate(from: currency, to: baseCurrency, on: t.tradeDate) { return looked }
        let warning = LedgerWarning.missingExchangeRate(currency, t.tradeDate)
        if !state.warnings.contains(warning) { state.warnings.append(warning) }
        return nil
    }

    private func addCash(_ amount: Decimal, _ currency: CurrencyCode, _ date: LocalDate, _ state: inout LedgerResult) {
        let updated = (state.cash[currency] ?? 0) + amount
        state.cash[currency] = updated
        if updated < 0, state.tracksCash {
            let warning = LedgerWarning.negativeCash(currency, date)
            if !state.warnings.contains(where: { if case .negativeCash(let c, _) = $0 { return c == currency }; return false }) {
                state.warnings.append(warning)
            }
        }
    }

    private func flow(_ date: LocalDate, inflow: Decimal = 0, outflow: Decimal = 0, _ state: inout LedgerResult) {
        if let index = state.flows.lastIndex(where: { $0.date == date }) {
            state.flows[index].inflow += inflow
            state.flows[index].outflow += outflow
        } else {
            state.flows.append(PortfolioFlow(date: date, inflow: inflow, outflow: outflow))
        }
    }

    // swiftlint:disable:next function_body_length
    private func apply(_ t: Transaction, to state: inout LedgerResult) throws {
        let rate = fx(t, t.currency, &state)
        let feeInBase = t.feeCurrency != nil && t.feeCurrency != t.currency // validator guarantees feeCurrency == base then
        let tradeFee: Decimal = feeInBase ? 0 : t.fees
        let baseFee: Decimal = feeInBase ? t.fees : 0
        func times(_ amount: Decimal, _ rate: Decimal?) -> Decimal? { rate.map { amount * $0 } }
        func plus(_ a: Decimal?, _ b: Decimal?) -> Decimal? { guard let a, let b else { return nil }; return a + b }

        switch t.type {
        case .buy:
            // Validator guarantees instrument, quantity and price.
            let key = PositionKey(instrumentID: t.instrumentID!, currency: t.currency)
            var position = state.positions[key] ?? PositionState(key: key)
            let quantity = t.quantity!, price = t.price!
            let gross = quantity * price + tradeFee
            position.quantity += quantity
            position.costBasis += gross
            position.costBasisBase = plus(position.costBasisBase, plus(times(gross, rate), baseFee))
            position.tradingFees += tradeFee
            position.tradingFeesBase = plus(position.tradingFeesBase, plus(times(tradeFee, rate), baseFee))
            position.accruedInterestPaid += t.accruedInterest ?? 0
            position.firstAcquired = position.firstAcquired ?? t.tradeDate
            state.positions[key] = position
            addCash(-(gross + (t.accruedInterest ?? 0)), t.currency, t.tradeDate, &state)
            if baseFee > 0 { addCash(-baseFee, baseCurrency, t.tradeDate, &state) }
            let purchaseBase = plus(times(gross + (t.accruedInterest ?? 0), rate), baseFee)
            state.totalPurchasesBase = plus(state.totalPurchasesBase, purchaseBase)
            if !state.tracksCash, let purchaseBase { flow(t.tradeDate, inflow: purchaseBase, &state) }

        case .sell, .bondRedemption:
            let key = PositionKey(instrumentID: t.instrumentID!, currency: t.currency)
            guard var position = state.positions[key] else { throw LedgerError.noPosition(t.id) }
            let quantity = t.quantity!, price = t.price!
            guard quantity <= position.quantity else {
                throw LedgerError.insufficientQuantity(t.id, available: position.quantity, requested: quantity)
            }
            let proceeds = quantity * price - tradeFee
            let fullExit = quantity == position.quantity
            // Average cost method: the sold share of the cost basis leaves the position.
            let costSold = fullExit ? position.costBasis : quantity * position.costBasis / position.quantity
            let costSoldBase: Decimal? = position.costBasisBase.map { fullExit ? $0 : quantity * $0 / position.quantity }
            position.realized += proceeds - costSold
            position.realizedBase = plus(position.realizedBase, plus(times(proceeds, rate), costSoldBase.map { -$0 })).map { $0 - baseFee }
            position.costBasis -= costSold
            position.costBasisBase = plus(position.costBasisBase, costSoldBase.map { -$0 })
            position.quantity -= quantity
            if position.quantity == 0 { position.costBasis = 0; position.costBasisBase = position.costBasisBase.map { _ in 0 } }
            position.tradingFees += tradeFee
            position.tradingFeesBase = plus(position.tradingFeesBase, plus(times(tradeFee, rate), baseFee))
            position.accruedInterestReceived += t.accruedInterest ?? 0
            state.positions[key] = position
            addCash(proceeds + (t.accruedInterest ?? 0), t.currency, t.tradeDate, &state)
            if baseFee > 0 { addCash(-baseFee, baseCurrency, t.tradeDate, &state) }
            if !state.tracksCash, let out = times(proceeds + (t.accruedInterest ?? 0), rate) {
                flow(t.tradeDate, outflow: out - baseFee, &state)
            }

        case .split:
            for (key, var position) in state.positions where key.instrumentID == t.instrumentID {
                // Quantity scales by n/d; the cost basis is unchanged, so average cost scales by d/n.
                position.quantity = position.quantity * Decimal(t.splitNumerator!) / Decimal(t.splitDenominator!)
                state.positions[key] = position
            }

        case .dividend, .coupon:
            let key = PositionKey(instrumentID: t.instrumentID!, currency: t.currency)
            var position = state.positions[key] ?? PositionState(key: key)
            let gross = t.amount!
            if t.type == .dividend {
                position.dividends += gross
                position.dividendsBase = plus(position.dividendsBase, times(gross, rate))
            } else {
                position.coupons += gross
                position.couponsBase = plus(position.couponsBase, times(gross, rate))
            }
            position.taxWithheld += t.taxWithheld
            position.taxWithheldBase = plus(position.taxWithheldBase, times(t.taxWithheld, rate))
            state.positions[key] = position
            addCash(gross - t.taxWithheld - tradeFee, t.currency, t.tradeDate, &state)
            if !state.tracksCash, let out = times(gross - t.taxWithheld - tradeFee, rate) { flow(t.tradeDate, outflow: out, &state) }

        case .interest:
            state.interestBase = plus(state.interestBase, times(t.amount!, rate))
            state.taxesBase = plus(state.taxesBase, times(t.taxWithheld, rate))
            addCash(t.amount! - t.taxWithheld, t.currency, t.tradeDate, &state)
            if !state.tracksCash, let out = times(t.amount! - t.taxWithheld, rate) { flow(t.tradeDate, outflow: out, &state) }

        case .fee:
            state.standaloneFeesBase = plus(state.standaloneFeesBase, times(t.amount!, rate))
            addCash(-t.amount!, t.currency, t.tradeDate, &state)
            if !state.tracksCash, let inflow = times(t.amount!, rate) { flow(t.tradeDate, inflow: inflow, &state) }

        case .tax:
            state.taxesBase = plus(state.taxesBase, times(t.amount!, rate))
            addCash(-t.amount!, t.currency, t.tradeDate, &state)
            if !state.tracksCash, let inflow = times(t.amount!, rate) { flow(t.tradeDate, inflow: inflow, &state) }

        case .deposit:
            addCash(t.amount!, t.currency, t.tradeDate, &state)
            let base = times(t.amount!, rate)
            state.netContributionsBase = plus(state.netContributionsBase, base)
            if let base { flow(t.tradeDate, inflow: base, &state) }

        case .withdrawal:
            addCash(-t.amount!, t.currency, t.tradeDate, &state)
            let base = times(t.amount!, rate)
            state.netContributionsBase = plus(state.netContributionsBase, base.map { -$0 })
            if let base { flow(t.tradeDate, outflow: base, &state) }

        case .fxConversion:
            // Internal transfer between cash balances; the fee is a cost, not a flow.
            addCash(-(t.amount! + tradeFee), t.currency, t.tradeDate, &state)
            addCash(t.counterAmount!, t.counterCurrency!, t.tradeDate, &state)
            if baseFee > 0 { addCash(-baseFee, baseCurrency, t.tradeDate, &state) }
            state.fxConversionFeesBase = plus(state.fxConversionFeesBase, plus(times(tradeFee, rate), baseFee))
        }
    }
}
