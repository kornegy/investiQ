import XCTest
@testable import InvestiQPresentation
import InvestiQCore
import InvestiQData
import InvestiQSecurity
import InvestiQServices
import InvestiQTestSupport

@MainActor
final class PortfolioViewModelTests: XCTestCase {
    func demoApp() async throws -> AppModel {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics, passwordDerivation: Argon2idKeyDerivation.testing,
                                                       clock: context.clock, httpClient: OfflineHTTPClient()))
        await app.startDemo()
        return app
    }

    func testOverviewShowsDemoPortfolioMetricsAndAllRanges() async throws {
        let app = try await demoApp()
        let model = OverviewViewModel(app: app)
        await model.load()
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(snapshot.portfolio.name, DemoPortfolioSeeder.portfolioName)
        XCTAssertNotNil(snapshot.valuation.totalValueBase)
        XCTAssertNotNil(snapshot.valuation.dividendsBase)
        XCTAssertGreaterThan(snapshot.valuation.couponsBase ?? 0, 0)
        XCTAssertFalse(model.allocationByType.isEmpty)
        XCTAssertEqual(model.allocationByType.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
        for range in DashboardRange.allCases {
            await model.setRange(range)
            XCTAssertTrue(model.hasChartData, "range \(range) should have at least two points in demo mode")
        }
        XCTAssertTrue(model.riskNotes.allSatisfy {
            if case .staleData = $0 { return false }
            return true
        }, "synthetic data is never reported as stale")
    }

    func testTransactionEditorValidatesAndSaves() async throws {
        let app = try await demoApp()
        let portfolios = PortfolioViewModel(app: app)
        await portfolios.load()
        let portfolio = try XCTUnwrap(portfolios.portfolios.first)
        let editor = TransactionEditorViewModel(app: app, portfolio: portfolio, locale: Locale(identifier: "cs_CZ"))
        await editor.load()
        editor.type = .buy
        editor.instrumentID = DemoUniverse.all[1].instrument.id
        editor.quantityText = "abc"
        guard case .failure(let invalid) = editor.makeTransaction() else { return XCTFail("invalid number accepted") }
        XCTAssertEqual(invalid.key, "transaction.error.invalidNumber")
        editor.quantityText = "5"
        editor.priceText = "700,5"
        editor.feesText = "49"
        guard case .success(let transaction) = editor.makeTransaction() else { return XCTFail("valid input rejected") }
        XCTAssertEqual(transaction.price, Decimal(string: "700.5"))
        XCTAssertEqual(transaction.source, .manual)
        await editor.save()
        XCTAssertTrue(editor.saved)

        let sell = TransactionEditorViewModel(app: app, portfolio: portfolio, locale: Locale(identifier: "cs_CZ"))
        await sell.load()
        sell.type = .sell
        sell.instrumentID = DemoUniverse.all[1].instrument.id
        sell.quantityText = "50"
        sell.priceText = "1"
        await sell.save()
        XCTAssertFalse(sell.saved)
        XCTAssertEqual(sell.error?.key, "transaction.error.insufficientQuantity")
    }

    func testVirtualPortfolioTransactionsAreMarkedSimulator() async throws {
        let app = try await demoApp()
        let model = PortfolioViewModel(app: app)
        model.kind = .virtual
        await model.createPortfolio(name: "Practice", baseCurrency: .czk)
        let portfolio = try XCTUnwrap(model.portfolios.first { $0.kind == .virtual })
        let editor = TransactionEditorViewModel(app: app, portfolio: portfolio)
        editor.type = .deposit
        editor.amountText = "1000"
        guard case .success(let deposit) = editor.makeTransaction() else { return XCTFail() }
        XCTAssertEqual(deposit.source, .simulator)
    }

    func testCSVImportPreviewThenConfirm() async throws {
        let app = try await demoApp()
        let model = PortfolioViewModel(app: app)
        await model.createPortfolio(name: "Imported", baseCurrency: .czk)
        let id = try XCTUnwrap(model.selectedPortfolioID)
        let importer = CSVImportViewModel(app: app, portfolioID: id)
        importer.preview(Data("date,type,amount,currency\n2026-01-02,deposit,1000,CZK\n2026-01-03,deposit,x,CZK\n".utf8))
        XCTAssertEqual(importer.parsed?.rows.count, 1)
        XCTAssertEqual(importer.parsed?.errors.count, 1)
        XCTAssertTrue(importer.canImport)
        await importer.confirmImport()
        XCTAssertEqual(importer.outcome?.imported, 1)
        XCTAssertFalse(importer.canImport)
        await model.select(id)
        XCTAssertEqual(model.transactions.count, 1)
        let exported = await model.exportCSV()
        XCTAssertTrue(exported?.contains("deposit") == true)
    }
}
