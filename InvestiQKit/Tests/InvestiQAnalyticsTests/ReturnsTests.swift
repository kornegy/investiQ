import XCTest
@testable import InvestiQAnalytics
import InvestiQCore
import InvestiQTestSupport

final class ReturnsTests: XCTestCase {
    func testXIRRMatchesSpreadsheetReference() throws {
        // Reference example used by spreadsheet XIRR documentation:
        // -10000 @ 2008-01-01, 2750 @ 2008-03-01, 4250 @ 2008-10-30, 3250 @ 2009-02-15, 2750 @ 2009-04-01 → 37.3362535 %
        let flows: [XIRR.CashFlow] = [
            .init(date: .d("2008-01-01"), amount: -10_000), .init(date: .d("2008-03-01"), amount: 2_750),
            .init(date: .d("2008-10-30"), amount: 4_250), .init(date: .d("2009-02-15"), amount: 3_250),
            .init(date: .d("2009-04-01"), amount: 2_750),
        ]
        XCTAssertEqual(try XCTUnwrap(XIRR.solve(flows)), 0.373362535, accuracy: 1e-7)
    }

    func testXIRRSimpleOneYearDoubling() throws {
        let flows: [XIRR.CashFlow] = [.init(date: .d("2023-01-01"), amount: -100), .init(date: .d("2024-01-01"), amount: 200)]
        // 365 days → exactly 100 % with the 365-day convention.
        XCTAssertEqual(try XCTUnwrap(XIRR.solve(flows)), 1.0, accuracy: 1e-9)
    }

    func testXIRRLossAndUndefinedCases() {
        let loss: [XIRR.CashFlow] = [.init(date: .d("2023-01-01"), amount: -100), .init(date: .d("2024-01-01"), amount: 50)]
        XCTAssertEqual(XIRR.solve(loss)!, -0.5, accuracy: 1e-9)
        XCTAssertNil(XIRR.solve([.init(date: .d("2023-01-01"), amount: 100), .init(date: .d("2024-01-01"), amount: 50)]),
                     "no sign change → undefined, not 0")
        XCTAssertNil(XIRR.solve([]))
    }

    func testTWRIgnoresTimingAndSizeOfFlows() throws {
        // Fund doubles in year 1 (100 → 200), then a 1 000 deposit, then +10 % (1 200 → 1 320).
        // TWR = 2.0 × 1.1 − 1 = 1.2 regardless of the deposit size.
        let points: [TimeWeightedReturn.Point] = [
            .init(date: .d("2022-01-01"), value: 0, inflow: 0),
            .init(date: .d("2022-01-02"), value: 100, inflow: 100),
            .init(date: .d("2023-01-01"), value: 200),
            .init(date: .d("2023-01-02"), value: 1_320, inflow: 1_000),
        ]
        XCTAssertEqual(try XCTUnwrap(TimeWeightedReturn.compute(points)), 2.0 * 1.1 - 1, accuracy: 1e-12)
    }

    func testTWRWithOutflowsAndNoFlowsEqualsSimpleReturn() throws {
        let simple: [TimeWeightedReturn.Point] = [.init(date: .d("2024-01-01"), value: 100), .init(date: .d("2024-02-01"), value: 105),
                                                  .init(date: .d("2024-03-01"), value: 110.25)]
        XCTAssertEqual(try XCTUnwrap(TimeWeightedReturn.compute(simple)), 0.1025, accuracy: 1e-12)
        // A withdrawal of 50 at the end of a day where the portfolio was worth 110 before it: +10 % for that day.
        let withdrawal: [TimeWeightedReturn.Point] = [.init(date: .d("2024-01-01"), value: 100),
                                                      .init(date: .d("2024-01-02"), value: 60, outflow: 50)]
        XCTAssertEqual(try XCTUnwrap(TimeWeightedReturn.compute(withdrawal)), 0.10, accuracy: 1e-12)
        XCTAssertNil(TimeWeightedReturn.compute([.init(date: .d("2024-01-01"), value: 100)]))
        XCTAssertNil(TimeWeightedReturn.annualized(0.05, from: .d("2024-01-01"), to: .d("2024-06-01")))
        XCTAssertEqual(TimeWeightedReturn.annualized(0.21, from: .d("2022-01-01"), to: .d("2024-01-01"))!, 0.1, accuracy: 0.001)
    }
}
