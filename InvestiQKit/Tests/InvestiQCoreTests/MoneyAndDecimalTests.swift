import XCTest
@testable import InvestiQCore
import InvestiQTestSupport

final class MoneyAndDecimalTests: XCTestCase {
    func testStrictParsingRejectsGarbage() {
        XCTAssertEqual(DecimalSupport.parse("123.45"), Decimal(string: "123.45"))
        XCTAssertEqual(DecimalSupport.parse("-0.001"), Decimal(string: "-0.001"))
        XCTAssertEqual(DecimalSupport.parse("1e-4"), Decimal(string: "0.0001"))
        XCTAssertNil(DecimalSupport.parse("12abc"))
        XCTAssertNil(DecimalSupport.parse(""))
        XCTAssertNil(DecimalSupport.parse("."))
        XCTAssertNil(DecimalSupport.parse("None"))
        XCTAssertNil(DecimalSupport.parse("1,5"))
        XCTAssertNil(DecimalSupport.parse("NaN"))
    }

    func testLocaleAwareParsing() {
        XCTAssertEqual(DecimalSupport.parse("1 234,56", locale: Locale(identifier: "cs_CZ")), .n("1234.56"))
        XCTAssertEqual(DecimalSupport.parse("1\u{00A0}234,5", locale: Locale(identifier: "ru_RU")), .n("1234.5"))
        XCTAssertEqual(DecimalSupport.parse("1,234.56", locale: Locale(identifier: "en_US")), .n("1234.56"))
    }

    func testDecimalArithmeticIsExact() {
        // 0.1 + 0.2 == 0.3 exactly with Decimal (it is not with Double).
        XCTAssertEqual(Decimal.n("0.1") + Decimal.n("0.2"), Decimal.n("0.3"))
        XCTAssertNotEqual(0.1 + 0.2, 0.3)
    }

    func testRoundingHalfAwayFromZero() {
        XCTAssertEqual(Decimal.n("2.345").rounded(scale: 2), .n("2.35"))
        XCTAssertEqual(Decimal.n("-2.345").rounded(scale: 2), .n("-2.35"))
        XCTAssertEqual(Decimal.n("2.344").rounded(scale: 2), .n("2.34"))
    }

    func testCanonicalStringRoundTrip() {
        for text in ["0", "1", "-1.5", "123456789.123456789", "0.000001"] {
            XCTAssertEqual(DecimalSupport.parse(Decimal.n(text).canonicalString), .n(text))
        }
    }

    func testMoneyRejectsCurrencyMismatch() throws {
        let a = Money(.n("10"), .czk), b = Money(.n("1"), .eur)
        XCTAssertThrowsError(try a.adding(b)) { error in
            XCTAssertEqual(error as? MoneyError, .currencyMismatch(.czk, .eur))
        }
        XCTAssertEqual(try a.adding(Money(.n("2.5"), .czk)), Money(.n("12.5"), .czk))
        XCTAssertEqual(Money(.n("100"), .eur).converted(to: .czk, rate: .n("25.1")), Money(.n("2510"), .czk))
    }

    func testCurrencyCodeValidation() {
        XCTAssertEqual(CurrencyCode(rawValue: "czk"), .czk)
        XCTAssertNil(CurrencyCode(rawValue: "CZ"))
        XCTAssertNil(CurrencyCode(rawValue: "C1K"))
        XCTAssertEqual(CurrencyCode.czk.minorUnits, 2)
        XCTAssertEqual(CurrencyCode(rawValue: "JPY")?.minorUnits, 0)
    }
}
