import XCTest
@testable import InvestiQCore
import InvestiQTestSupport

final class LocalDateTests: XCTestCase {
    func testEpochRoundTrip() {
        XCTAssertEqual(LocalDate.d("1970-01-01").daysSinceEpoch, 0)
        XCTAssertEqual(LocalDate.d("2000-03-01").daysSinceEpoch, 11_017)
        for offset in stride(from: -50_000, through: 50_000, by: 997) {
            XCTAssertEqual(LocalDate(daysSinceEpoch: offset).daysSinceEpoch, offset)
        }
    }

    func testValidationRejectsImpossibleDates() {
        XCTAssertNil(LocalDate(iso: "2023-02-29"))
        XCTAssertNotNil(LocalDate(iso: "2024-02-29"))
        XCTAssertNil(LocalDate(iso: "1900-02-29")) // not a leap year
        XCTAssertNotNil(LocalDate(iso: "2000-02-29")) // leap year (divisible by 400)
        XCTAssertNil(LocalDate(iso: "2024-13-01"))
        XCTAssertNil(LocalDate(iso: "2024-1-1"))
        XCTAssertNil(LocalDate(iso: "garbage"))
    }

    func testAddingMonthsClampsToMonthEnd() {
        XCTAssertEqual(LocalDate.d("2024-01-31").adding(months: 1), .d("2024-02-29"))
        XCTAssertEqual(LocalDate.d("2023-01-31").adding(months: 1), .d("2023-02-28"))
        XCTAssertEqual(LocalDate.d("2024-03-31").adding(months: -1), .d("2024-02-29"))
        XCTAssertEqual(LocalDate.d("2024-12-15").adding(months: 1), .d("2025-01-15"))
        XCTAssertEqual(LocalDate.d("2025-01-15").adding(months: -13), .d("2023-12-15"))
    }

    func testWeekdays() {
        XCTAssertEqual(LocalDate.d("2026-11-24").isoWeekday, 2) // Tuesday
        XCTAssertEqual(LocalDate.d("1970-01-01").isoWeekday, 4) // Thursday
        XCTAssertTrue(LocalDate.d("2026-11-29").isWeekend) // Sunday
        XCTAssertEqual(LocalDate.d("2026-11-23").previousWeekday, .d("2026-11-20")) // Monday → Friday
    }

    func testDaysBetween() {
        XCTAssertEqual(LocalDate.d("2024-01-01").days(to: .d("2025-01-01")), 366)
        XCTAssertEqual(LocalDate.d("2025-01-01").days(to: .d("2024-01-01")), -366)
    }

    func testCodableUsesISO() throws {
        let data = try JSONEncoder().encode([LocalDate.d("2026-05-07")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"2026-05-07\"]")
        XCTAssertThrowsError(try JSONDecoder().decode([LocalDate].self, from: Data("[\"2026-02-30\"]".utf8)))
    }

    func testConversionFromInstantRespectsTimeZone() {
        let instant = Date.utc("2026-01-01T23:30:00Z")
        XCTAssertEqual(LocalDate(instant, timeZone: TimeZone(identifier: "UTC")!), .d("2026-01-01"))
        XCTAssertEqual(LocalDate(instant, timeZone: TimeZone(identifier: "Europe/Prague")!), .d("2026-01-02"))
    }
}
