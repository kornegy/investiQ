import XCTest
@testable import InvestiQContent

final class LessonCatalogTests: XCTestCase {
    /// The 21 mandatory topics of spec §20.
    static let mandatory = ["what-is-investing", "what-is-a-stock", "what-is-a-bond", "what-is-an-etf", "stock-exchange",
                            "how-a-broker-works", "how-prices-form", "dividends", "coupons", "compound-interest", "inflation",
                            "diversification", "volatility", "market-risk", "fees", "currency-risk", "orders",
                            "investing-vs-speculation", "recognising-fraud", "risk-and-return", "past-performance"]

    func testAllLanguagesLoadWithIdenticalStructure() throws {
        let english = try LessonCatalog.load(language: "en")
        XCTAssertEqual(Set(english.map(\.id)), Set(Self.mandatory))
        XCTAssertEqual(english.map(\.order), Array(1...21))
        XCTAssertEqual(english.map(\.stage), english.map(\.stage).sorted(), "the path goes from stage 1 to 4")
        for language in ["ru", "cs"] {
            let other = try LessonCatalog.load(language: language)
            XCTAssertEqual(other.map(\.id), english.map(\.id), language)
            XCTAssertEqual(other.map(\.calculator), english.map(\.calculator), language)
            XCTAssertEqual(other.map { $0.quiz.map(\.correctIndex) }, english.map { $0.quiz.map(\.correctIndex) }, language)
            XCTAssertNotEqual(other.first?.title, english.first?.title, "\(language) is translated")
        }
    }

    func testEveryLessonIsComplete() throws {
        for language in LessonCatalog.supportedLanguages {
            for lesson in try LessonCatalog.load(language: language) {
                XCTAssertGreaterThanOrEqual(lesson.sections.count, 2, lesson.id)
                XCTAssertEqual(lesson.keyPoints.count, 3, lesson.id)
                XCTAssertFalse(lesson.analogy.isEmpty, lesson.id)
                XCTAssertFalse(lesson.quiz.isEmpty, lesson.id)
                for question in lesson.quiz {
                    XCTAssertTrue(question.options.indices.contains(question.correctIndex), lesson.id)
                    XCTAssertFalse(question.explanation.isEmpty, lesson.id)
                }
            }
        }
    }

    func testUnsupportedLanguageFallsBackToEnglish() throws {
        XCTAssertEqual(LessonCatalog.language(for: "de"), "en")
        XCTAssertEqual(LessonCatalog.language(for: nil), "en")
        XCTAssertEqual(try LessonCatalog.load(language: "de").first?.title, try LessonCatalog.load(language: "en").first?.title)
    }
}

final class DirectoryAndCalendarContentTests: XCTestCase {
    func testBrokerDirectoryIsVerifiedNeutralAndClean() throws {
        let (brokers, verifiedOn) = try BrokerCatalog.load()
        XCTAssertGreaterThanOrEqual(brokers.count, 5)
        XCTAssertEqual(brokers.map(\.brand), brokers.map(\.brand).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                       "alphabetical — no ranking")
        for broker in brokers {
            XCTAssertFalse(broker.sources.isEmpty, broker.id)
            XCTAssertLessThanOrEqual(broker.verifiedOn, verifiedOn)
            let urls = [broker.registerURL] + broker.sources + [broker.websiteURL].compactMap { $0 }
            for url in urls {
                XCTAssertEqual(url.scheme, "https", "\(broker.id): \(url)")
                let query = url.query?.lowercased() ?? ""
                XCTAssertFalse(["ref=", "utm_", "affiliate", "aff=", "partner", "promo"].contains { query.contains($0) },
                               "\(broker.id): no referral or tracking parameters")
            }
            if let protection = broker.investorProtection, let percent = protection.coveragePercent {
                XCTAssertTrue((1...100).contains(percent))
            }
            // Unverified fast-changing facts stay empty rather than guessed.
            XCTAssertNil(broker.fees, broker.id)
            XCTAssertNil(broker.fxFees, broker.id)
        }
    }
}
