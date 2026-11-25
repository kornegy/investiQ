import XCTest
@testable import InvestiQCore

final class IdentifierTests: XCTestCase {
    func testValidISINs() {
        // Check digits verified independently (Python reference implementation).
        for isin in ["US0378331005", "IE00B4L5Y983", "CZ0005112300", "DE0007164600", "CZ0001005037", "XS2314659447"] {
            XCTAssertNotNil(ISIN(rawValue: isin), isin)
        }
        XCTAssertEqual(ISIN(rawValue: " us0378331005 ")?.rawValue, "US0378331005")
        XCTAssertEqual(ISIN(rawValue: "CZ0005112300")?.countryCode, "CZ")
    }

    func testInvalidISINs() {
        XCTAssertNil(ISIN(rawValue: "US0378331006")) // wrong check digit
        XCTAssertNil(ISIN(rawValue: "US037833100")) // too short
        XCTAssertNil(ISIN(rawValue: "1S0378331005")) // country must be letters
        XCTAssertNil(ISIN(rawValue: "US03783310X5")) // check digit must be numeric
    }

    func testTickerAndMIC() {
        XCTAssertEqual(Ticker(rawValue: "cez.pr")?.rawValue, "CEZ.PR")
        XCTAssertNil(Ticker(rawValue: "A B"))
        XCTAssertNil(Ticker(rawValue: ""))
        XCTAssertEqual(MIC(rawValue: "xpra")?.rawValue, "XPRA")
        XCTAssertNil(MIC(rawValue: "XPR"))
        let key = ListingKey(mic: MIC(rawValue: "XPRA"), ticker: Ticker(rawValue: "CEZ")!)
        XCTAssertEqual(key.description, "XPRA:CEZ")
    }
}
