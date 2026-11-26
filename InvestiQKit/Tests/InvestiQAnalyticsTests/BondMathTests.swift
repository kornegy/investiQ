import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class BondMathTests: XCTestCase {
    func bond(coupon: Decimal, frequency: Int, dayCount: DayCountConvention, issue: String, maturity: String,
              calls: [CallDate] = []) -> BondMath {
        BondMath(terms: BondDetails(issuerType: .government, faceValue: 1_000, couponRate: coupon, couponFrequency: frequency,
                                    dayCount: dayCount, issueDate: .d(issue), maturityDate: .d(maturity), callSchedule: calls))
    }

    func testDayCountConventions() {
        XCTAssertEqual(BondMath.yearFraction(.d("2024-01-15"), .d("2024-03-01"), .thirty360US) * 360, 46, accuracy: 1e-9)
        XCTAssertEqual(BondMath.yearFraction(.d("2024-01-31"), .d("2024-03-31"), .thirty360US) * 360, 60, accuracy: 1e-9)
        XCTAssertEqual(BondMath.yearFraction(.d("2024-01-30"), .d("2024-02-29"), .thirtyE360) * 360, 29, accuracy: 1e-9)
        XCTAssertEqual(BondMath.yearFraction(.d("2024-01-01"), .d("2024-07-01"), .actual360), 182.0 / 360, accuracy: 1e-12)
        XCTAssertEqual(BondMath.yearFraction(.d("2024-01-01"), .d("2025-01-01"), .actual365Fixed), 366.0 / 365, accuracy: 1e-12)
    }

    func testScheduleKeepsEndOfMonth() {
        let b = bond(coupon: 0.05, frequency: 2, dayCount: .thirty360US, issue: "2023-02-28", maturity: "2025-02-28")
        XCTAssertEqual(b.couponDates().map(\.iso), ["2023-08-31", "2024-02-29", "2024-08-31", "2025-02-28"])
    }

    func testAccruedInterest() {
        // 30/360, 5 % semi-annual, last coupon 15 Jan, settlement 1 Mar: 46 days → 5 × 46/360 = 0.638889.
        let us = bond(coupon: 0.05, frequency: 2, dayCount: .thirty360US, issue: "2020-01-15", maturity: "2030-01-15")
        XCTAssertEqual(us.accruedInterest(settlement: .d("2024-03-01")), 5 * 46.0 / 360, accuracy: 1e-9)
        // ACT/ACT ICMA, 4.5 % annual, 181 of 365 days elapsed → 4.5 × 181/365 = 2.231507.
        let cz = bond(coupon: 0.045, frequency: 1, dayCount: .actualActualICMA, issue: "2020-11-11", maturity: "2030-11-11")
        XCTAssertEqual(cz.accruedInterest(settlement: .d("2026-05-11")), 4.5 * 181.0 / 365, accuracy: 1e-9)
        XCTAssertEqual(cz.accruedInterest(settlement: .d("2026-11-11")), 0, accuracy: 1e-12, "no accrual on a coupon date")
    }

    func testParBondYieldEqualsCouponAndClosedFormDuration() throws {
        // 5-year 6 % annual bond at par on a coupon date: YTM = 6 %.
        // Macaulay duration closed form: (1+y)/y · (1 − (1+y)^−N) = 4.465106 years.
        let b = bond(coupon: 0.06, frequency: 1, dayCount: .actualActualICMA, issue: "2021-06-01", maturity: "2031-06-01")
        let settlement = LocalDate.d("2026-06-01")
        let ytm = try XCTUnwrap(b.yieldToMaturity(clean: 100, settlement: settlement))
        XCTAssertEqual(ytm, 0.06, accuracy: 1e-9)
        let risk = try XCTUnwrap(b.riskMeasures(yield: ytm, settlement: settlement))
        let closedForm = 1.06 / 0.06 * (1 - pow(1.06, -5))
        XCTAssertEqual(risk.macaulay, closedForm, accuracy: 1e-6)
        XCTAssertEqual(risk.modified, closedForm / 1.06, accuracy: 1e-6)
        XCTAssertGreaterThan(risk.convexity, 0)
        XCTAssertEqual(b.currentYield(clean: 100)!, 0.06, accuracy: 1e-12)
    }

    func testPriceYieldInverseAndRelationship() throws {
        let b = bond(coupon: 0.045, frequency: 1, dayCount: .actualActualICMA, issue: "2020-11-11", maturity: "2030-11-11")
        let settlement = LocalDate.d("2026-03-15")
        for clean in [92.0, 100.0, 104.5] {
            let ytm = try XCTUnwrap(b.yieldToMaturity(clean: clean, settlement: settlement))
            let dirty = try XCTUnwrap(b.dirtyPrice(yield: ytm, settlement: settlement))
            XCTAssertEqual(dirty - b.accruedInterest(settlement: settlement), clean, accuracy: 1e-7)
        }
        let low = try XCTUnwrap(b.yieldToMaturity(clean: 92, settlement: settlement))
        let high = try XCTUnwrap(b.yieldToMaturity(clean: 104.5, settlement: settlement))
        XCTAssertGreaterThan(low, high, "lower price ⇔ higher yield")
        // Rising yields reduce the price; the duration approximation is close for small shifts.
        let change = try XCTUnwrap(b.cleanPriceChange(clean: 100, settlement: settlement, yieldShift: 0.01))
        XCTAssertLessThan(change, 0)
        let ytm = try XCTUnwrap(b.yieldToMaturity(clean: 100, settlement: settlement))
        let risk = try XCTUnwrap(b.riskMeasures(yield: ytm, settlement: settlement))
        let dirty = b.dirtyPrice(clean: 100, settlement: settlement)
        let approximation = dirty * (-risk.modified * 0.01 + 0.5 * risk.convexity * 0.0001)
        XCTAssertEqual(change, approximation, accuracy: 0.02)
    }

    func testZeroCouponBond() throws {
        // Price 90, two years to maturity (ACT/365F, 730 days): y = (100/90)^(365/730) − 1; duration = 2 years.
        let b = bond(coupon: 0, frequency: 0, dayCount: .actual365Fixed, issue: "2020-01-01", maturity: "2027-01-01")
        let settlement = LocalDate.d("2025-01-01")
        let ytm = try XCTUnwrap(b.yieldToMaturity(clean: 90, settlement: settlement))
        XCTAssertEqual(ytm, pow(100.0 / 90.0, 365.0 / 730.0) - 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b.riskMeasures(yield: ytm, settlement: settlement)).macaulay, 2, accuracy: 1e-9)
        XCTAssertEqual(b.accruedInterest(settlement: settlement), 0)
    }

    func testYieldToCallAndHoldVersusSell() throws {
        let b = bond(coupon: 0.0525, frequency: 2, dayCount: .thirtyE360, issue: "2022-06-30", maturity: "2029-06-30",
                     calls: [CallDate(date: .d("2027-06-30"), pricePercent: 101)])
        let settlement = LocalDate.d("2026-06-30")
        let ytc = try XCTUnwrap(b.yieldToCall(clean: 102.8, settlement: settlement))
        XCTAssertEqual(ytc.call.date, .d("2027-06-30"))
        let ytm = try XCTUnwrap(b.yieldToMaturity(clean: 102.8, settlement: settlement))
        XCTAssertLessThan(ytc.yield, ytm, "a premium bond called early yields less")
        let comparison = b.holdVersusSell(settlement: settlement, saleDate: .d("2027-06-30"), saleYield: ytm + 0.02)
        XCTAssertEqual(comparison.holdToMaturityCashPer100, 100 + 6 * 2.625, accuracy: 1e-9)
        XCTAssertEqual(comparison.couponsUntilSalePer100, 2 * 2.625, accuracy: 1e-9)
        XCTAssertLessThan(comparison.saleCleanPrice!, 100, "selling after yields rose realises a lower price")
    }

    func testMaturedBondHasNoFlows() {
        let b = bond(coupon: 0.05, frequency: 1, dayCount: .actualActualICMA, issue: "2010-01-01", maturity: "2020-01-01")
        XCTAssertNil(b.yieldToMaturity(clean: 100, settlement: .d("2021-01-01")))
        XCTAssertEqual(b.accruedInterest(settlement: .d("2021-01-01")), 0)
    }
}
