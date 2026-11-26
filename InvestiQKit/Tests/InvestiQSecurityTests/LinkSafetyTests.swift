import XCTest
@testable import InvestiQSecurity

final class LinkSafetyTests: XCTestCase {
    func inspect(_ text: String) throws -> LinkInspection { try LinkSafety.inspect(text).get() }

    func testPlainHTTPSLink() throws {
        let result = try inspect("https://www.cnb.cz/en/")
        XCTAssertEqual(result.displayHost, "www.cnb.cz")
        XCTAssertEqual(result.warnings, [])
    }

    func testRejectsDangerousSchemes() {
        XCTAssertEqual(LinkSafety.inspect("javascript:alert(1)").failureValue, .unsupportedScheme("javascript"))
        XCTAssertEqual(LinkSafety.inspect("file:///etc/passwd").failureValue, .unsupportedScheme("file"))
        XCTAssertEqual(LinkSafety.inspect("https://").failureValue, .missingHost)
    }

    func testWarnings() throws {
        XCTAssertEqual(try inspect("http://example.com").warnings, [.insecureHTTP])
        XCTAssertEqual(try inspect("https://192.168.1.1/login").warnings, [.ipAddressHost])
        XCTAssertEqual(try inspect("https://user:pass@bank.example").warnings, [.credentialsInURL])
        XCTAssertEqual(try inspect("https://example.com:8443").warnings, [.nonStandardPort])
    }

    func testPunycodeDecoding() {
        XCTAssertEqual(Punycode.decode("bcher-kva"), "bücher")
        XCTAssertEqual(Punycode.decode("80ak6aa92e"), "аррӏе") // Cyrillic look-alike of "apple"
        XCTAssertNil(Punycode.decode("!!!"))
    }

    func testHomographDomainIsFlagged() throws {
        let result = try inspect("https://xn--80ak6aa92e.com/")
        XCTAssertEqual(result.displayHost, "аррӏе.com")
        XCTAssertEqual(result.asciiHost, "xn--80ak6aa92e.com")
        XCTAssertTrue(result.warnings.contains(.internationalizedDomain))
        XCTAssertTrue(result.warnings.contains(.possibleLookalike))
    }

    func testLegitimateIDNIsMarkedButNotLookalike() throws {
        let result = try inspect("https://xn--bcher-kva.example/")
        XCTAssertEqual(result.displayHost, "bücher.example")
        XCTAssertEqual(result.warnings, [.internationalizedDomain])
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}
