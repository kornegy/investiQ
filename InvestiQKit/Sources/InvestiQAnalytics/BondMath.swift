import Foundation
import InvestiQCore

/// Bond analytics per 100 of face value (docs/FINANCIAL_METHODOLOGY.md §5, M-BND).
public struct BondMath: Sendable {
    public let terms: BondDetails

    public init(terms: BondDetails) { self.terms = terms }

    var frequency: Int { terms.couponFrequency }
    /// Coupon per period per 100 face.
    var periodCoupon: Double { frequency == 0 ? 0 : 100 * terms.couponRate.doubleValue / Double(frequency) }
    var annualCoupon: Double { 100 * terms.couponRate.doubleValue }

    // MARK: Day counts

    /// Year fraction between two dates under a day-count convention (non-ICMA conventions).
    public static func yearFraction(_ start: LocalDate, _ end: LocalDate, _ convention: DayCountConvention) -> Double {
        switch convention {
        case .actual360: return Double(start.days(to: end)) / 360
        case .actual365Fixed, .actualActualICMA: return Double(start.days(to: end)) / 365
        case .thirty360US:
            var d1 = start.day, d2 = end.day
            if d1 == 31 { d1 = 30 }
            if d2 == 31 && d1 >= 30 { d2 = 30 }
            return thirty360Days(start, end, d1, d2) / 360
        case .thirtyE360:
            return thirty360Days(start, end, min(start.day, 30), min(end.day, 30)) / 360
        }
    }

    /// 360·ΔY + 30·ΔM + ΔD with already-adjusted day numbers (split up for the type checker).
    private static func thirty360Days(_ start: LocalDate, _ end: LocalDate, _ d1: Int, _ d2: Int) -> Double {
        let years: Int = end.year - start.year
        let months: Int = end.month - start.month
        let days: Int = d2 - d1
        let total: Int = 360 * years + 30 * months + days
        return Double(total)
    }

    // MARK: Schedule

    /// Coupon dates, generated backwards from maturity (end-of-month rule preserved).
    public func couponDates() -> [LocalDate] {
        guard frequency > 0 else { return [terms.maturityDate] }
        let step = 12 / frequency
        let endOfMonth = terms.maturityDate.isLastDayOfMonth
        var dates: [LocalDate] = []
        var index = 0
        let earliest = terms.issueDate ?? terms.maturityDate.adding(years: -100)
        while true {
            var date = terms.maturityDate.adding(months: -step * index)
            if endOfMonth { date = LocalDate(year: date.year, month: date.month, day: LocalDate.daysInMonth(year: date.year, month: date.month))! }
            if date <= earliest { break }
            dates.append(date)
            index += 1
            if index > 2_000 { break } // safety bound for malformed terms
        }
        return dates.reversed()
    }

    /// Previous and next coupon dates around `settlement` (previous may be the issue date or an
    /// extrapolated date before the first coupon).
    public func couponPeriod(containing settlement: LocalDate) -> (previous: LocalDate, next: LocalDate)? {
        guard frequency > 0, settlement < terms.maturityDate else { return nil }
        let dates = couponDates()
        guard let next = dates.first(where: { $0 > settlement }) else { return nil }
        let previous = dates.last(where: { $0 <= settlement }) ?? next.adding(months: -12 / frequency)
        return (previous, next)
    }

    // MARK: Accrued interest and prices

    /// M-BND-AI: accrued interest per 100 face at settlement.
    public func accruedInterest(settlement: LocalDate) -> Double {
        guard let period = couponPeriod(containing: settlement) else { return 0 }
        if terms.dayCount == .actualActualICMA {
            let elapsed = Double(period.previous.days(to: settlement))
            let length = Double(period.previous.days(to: period.next))
            return length > 0 ? periodCoupon * elapsed / length : 0
        }
        return annualCoupon * Self.yearFraction(period.previous, settlement, terms.dayCount)
    }

    public func dirtyPrice(clean: Double, settlement: LocalDate) -> Double { clean + accruedInterest(settlement: settlement) }

    /// Remaining cash flows after settlement with their time in coupon periods from settlement.
    func cashFlows(settlement: LocalDate, redemption: LocalDate? = nil, redemptionPrice: Double = 100) -> [(periods: Double, amount: Double)] {
        let end = redemption ?? terms.maturityDate
        guard settlement < end else { return [] }
        guard frequency > 0 else {
            return [(Self.yearFraction(settlement, end, terms.dayCount == .actualActualICMA ? .actual365Fixed : terms.dayCount), redemptionPrice)]
        }
        guard let period = couponPeriod(containing: settlement) else { return [] }
        let w: Double
        if terms.dayCount == .actualActualICMA {
            w = Double(settlement.days(to: period.next)) / Double(period.previous.days(to: period.next))
        } else {
            w = Self.yearFraction(settlement, period.next, terms.dayCount) * Double(frequency)
        }
        let dates = couponDates().filter { $0 > settlement && $0 <= end }
        var flows: [(Double, Double)] = []
        for (index, date) in dates.enumerated() {
            var amount = periodCoupon
            if date == dates.last { amount += redemptionPrice }
            flows.append((Double(index) + w, amount))
        }
        if dates.last != end { flows.append((Double(dates.count) + w, redemptionPrice)) } // call date between coupons
        return flows
    }

    /// Dirty price per 100 for a yield (street convention, periodic compounding).
    public func dirtyPrice(yield: Double, settlement: LocalDate, redemption: LocalDate? = nil, redemptionPrice: Double = 100) -> Double? {
        let flows = cashFlows(settlement: settlement, redemption: redemption, redemptionPrice: redemptionPrice)
        guard !flows.isEmpty else { return nil }
        if frequency == 0 { return flows[0].amount / pow(1 + yield, flows[0].periods) }
        let base = 1 + yield / Double(frequency)
        guard base > 0 else { return nil }
        return flows.reduce(0) { $0 + $1.amount / pow(base, $1.periods) }
    }

    /// M-BND-YTM: yield that equates the discounted cash flows with the dirty price.
    public func yieldToMaturity(clean: Double, settlement: LocalDate) -> Double? {
        yield(dirty: dirtyPrice(clean: clean, settlement: settlement), settlement: settlement, redemption: nil, redemptionPrice: 100)
    }

    func yield(dirty: Double, settlement: LocalDate, redemption: LocalDate?, redemptionPrice: Double) -> Double? {
        guard dirty > 0 else { return nil }
        func f(_ y: Double) -> Double? { dirtyPrice(yield: y, settlement: settlement, redemption: redemption, redemptionPrice: redemptionPrice).map { $0 - dirty } }
        var y = terms.couponRate.doubleValue > 0 ? terms.couponRate.doubleValue : 0.03
        for _ in 0..<50 {
            guard let value = f(y) else { break }
            if abs(value) < 1e-10 { return y }
            let h = 1e-6
            guard let up = f(y + h) else { break }
            let slope = (up - value) / h
            guard slope != 0 else { break }
            let next = y - value / slope
            guard next.isFinite, next > -0.99, next < 1.0 else { break }
            y = next
        }
        var low = -0.99, high = 1.0
        guard let fLowStart = f(low), let fHigh = f(high), fLowStart.sign != fHigh.sign else { return nil }
        var fLow = fLowStart
        for _ in 0..<200 {
            let mid = (low + high) / 2
            guard let fMid = f(mid) else { return nil }
            if abs(fMid) < 1e-10 || high - low < 1e-12 { return mid }
            if fMid.sign == fLow.sign { low = mid; fLow = fMid } else { high = mid }
        }
        return nil
    }

    public func currentYield(clean: Double) -> Double? {
        clean > 0 ? annualCoupon / clean : nil
    }

    public struct RiskMeasures: Sendable, Equatable {
        /// Macaulay duration in years.
        public var macaulay: Double
        /// Modified duration: % price change per 1.00 change in yield (≈ per 100 bp).
        public var modified: Double
        public var convexity: Double
    }

    public func riskMeasures(yield: Double, settlement: LocalDate) -> RiskMeasures? {
        let flows = cashFlows(settlement: settlement)
        guard !flows.isEmpty else { return nil }
        let f = Double(max(frequency, 1))
        let base = frequency == 0 ? 1 + yield : 1 + yield / f
        var price = 0.0, weighted = 0.0, convexitySum = 0.0
        for flow in flows {
            let pv = flow.amount / pow(base, flow.periods)
            let years = frequency == 0 ? flow.periods : flow.periods / f
            price += pv
            weighted += years * pv
            convexitySum += years * (years + 1 / f) * pv
        }
        guard price > 0 else { return nil }
        let macaulay = weighted / price
        return RiskMeasures(macaulay: macaulay, modified: macaulay / base, convexity: convexitySum / (price * base * base))
    }

    /// Yield to the first call date (if callable) and yield to worst.
    public func yieldToCall(clean: Double, settlement: LocalDate) -> (call: CallDate, yield: Double)? {
        guard let call = terms.callSchedule.filter({ $0.date > settlement }).min(by: { $0.date < $1.date }) else { return nil }
        let dirty = dirtyPrice(clean: clean, settlement: settlement)
        return yield(dirty: dirty, settlement: settlement, redemption: call.date, redemptionPrice: call.pricePercent.doubleValue).map { (call, $0) }
    }

    /// Full repricing for a parallel yield change (used by stress tests).
    public func cleanPriceChange(clean: Double, settlement: LocalDate, yieldShift: Double) -> Double? {
        guard let ytm = yieldToMaturity(clean: clean, settlement: settlement),
              let shifted = dirtyPrice(yield: ytm + yieldShift, settlement: settlement) else { return nil }
        return shifted - accruedInterest(settlement: settlement) - clean
    }

    /// Value at maturity if held (coupons + redemption, no reinvestment) vs. value if sold at a
    /// different yield on `saleDate` — illustrates hold-to-maturity vs secondary-market sale.
    public struct HoldVersusSell: Sendable, Equatable {
        public var holdToMaturityCashPer100: Double
        public var saleCleanPrice: Double?
        public var couponsUntilSalePer100: Double
    }

    public func holdVersusSell(settlement: LocalDate, saleDate: LocalDate, saleYield: Double) -> HoldVersusSell {
        let flows = cashFlows(settlement: settlement)
        let hold = flows.reduce(0) { $0 + $1.amount }
        let couponsBeforeSale = couponDates().filter { $0 > settlement && $0 <= saleDate }.count
        let sale = dirtyPrice(yield: saleYield, settlement: saleDate).map { $0 - accruedInterest(settlement: saleDate) }
        return HoldVersusSell(holdToMaturityCashPer100: hold, saleCleanPrice: sale, couponsUntilSalePer100: Double(couponsBeforeSale) * periodCoupon)
    }
}
