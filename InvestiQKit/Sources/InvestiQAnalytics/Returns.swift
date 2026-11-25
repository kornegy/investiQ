import Foundation
import InvestiQCore

/// Money-weighted return (XIRR) — docs/FINANCIAL_METHODOLOGY.md §2, M-RET-XIRR.
public enum XIRR {
    public struct CashFlow: Sendable, Hashable {
        public var date: LocalDate
        /// Investor perspective: contributions negative, withdrawals/terminal value positive.
        public var amount: Double
        public init(date: LocalDate, amount: Double) { self.date = date; self.amount = amount }
    }

    static let lowerBound = -0.9999
    static let upperBound = 10.0
    static let maxIterations = 200

    static func npv(_ rate: Double, _ flows: [CashFlow], _ start: LocalDate) -> Double {
        flows.reduce(0) { sum, flow in
            let years = Double(start.days(to: flow.date)) / 365
            return sum + flow.amount / pow(1 + rate, years)
        }
    }

    static func derivative(_ rate: Double, _ flows: [CashFlow], _ start: LocalDate) -> Double {
        flows.reduce(0) { sum, flow in
            let years = Double(start.days(to: flow.date)) / 365
            return sum - years * flow.amount / pow(1 + rate, years + 1)
        }
    }

    /// Annualised internal rate of return, or `nil` when it is undefined (no sign change) or does not converge.
    public static func solve(_ flows: [CashFlow]) -> Double? {
        let cleaned = flows.filter { $0.amount != 0 && $0.amount.isFinite }.sorted { $0.date < $1.date }
        guard cleaned.contains(where: { $0.amount > 0 }), cleaned.contains(where: { $0.amount < 0 }),
              let start = cleaned.first?.date else { return nil }
        let scale = cleaned.map { abs($0.amount) }.max() ?? 1
        let tolerance = 1e-9 * scale

        // Newton–Raphson from 10 %.
        var rate = 0.1
        for _ in 0..<50 {
            let value = npv(rate, cleaned, start)
            if abs(value) < tolerance { return rate }
            let slope = derivative(rate, cleaned, start)
            guard slope != 0, slope.isFinite else { break }
            let next = rate - value / slope
            guard next.isFinite, next > lowerBound, next < upperBound else { break }
            rate = next
        }
        // Fallback: bisection on [−99.99 %, +1000 %] if the bracket contains a root.
        var low = lowerBound, high = upperBound
        var fLow = npv(low, cleaned, start)
        let fHigh = npv(high, cleaned, start)
        guard fLow.sign != fHigh.sign else { return nil }
        for _ in 0..<maxIterations {
            let mid = (low + high) / 2
            let fMid = npv(mid, cleaned, start)
            if abs(fMid) < tolerance || (high - low) < 1e-12 { return mid }
            if fMid.sign == fLow.sign { low = mid; fLow = fMid } else { high = mid }
        }
        return nil
    }
}

/// Time-weighted return — M-RET-TWR. Inflows are assumed at the start of the day, outflows at the end.
public enum TimeWeightedReturn {
    public struct Point: Sendable, Hashable {
        public var date: LocalDate
        /// Portfolio value at the end of the day (after outflows have left).
        public var value: Double
        public var inflow: Double
        public var outflow: Double
        public init(date: LocalDate, value: Double, inflow: Double = 0, outflow: Double = 0) {
            self.date = date; self.value = value; self.inflow = inflow; self.outflow = outflow
        }
    }

    /// r_t = (V_t + O_t) / (V_{t−1} + I_t) − 1; TWR = Π(1 + r_t) − 1. `nil` with fewer than two points
    /// or when a sub-period has no capital at risk.
    public static func compute(_ points: [Point]) -> Double? {
        guard points.count >= 2 else { return nil }
        var growth = 1.0
        var periods = 0
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            let denominator = previous.value + current.inflow
            guard denominator > 0 else { continue } // nothing invested yet
            growth *= (current.value + current.outflow) / denominator
            periods += 1
        }
        return periods > 0 ? growth - 1 : nil
    }

    /// Annualised only for periods of at least one year (short periods are never annualised).
    public static func annualized(_ total: Double, from start: LocalDate, to end: LocalDate) -> Double? {
        let days = Double(start.days(to: end))
        guard days >= 365, total > -1 else { return nil }
        return pow(1 + total, 365 / days) - 1
    }
}
