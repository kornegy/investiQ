import XCTest
@testable import InvestiQPresentation
import InvestiQCore
import InvestiQData
import InvestiQSecurity
import InvestiQTestSupport

@MainActor
final class MarketViewModelTests: XCTestCase {
    func demoApp() async throws -> AppModel {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.startDemo()
        return app
    }

    func testExplorerLoadsDemoLibraryWithSyntheticQuotes() async throws {
        let app = try await demoApp()
        let model = MarketExplorerViewModel(app: app)
        await model.load()
        XCTAssertEqual(model.library.count, DemoUniverse.all.count)
        XCTAssertTrue(model.quotes.values.allSatisfy { $0.value?.metadata.delay == .synthetic })

        model.kindFilter = .etf
        XCTAssertTrue(model.filteredLibrary.allSatisfy { $0.instrument.kind == .etf })
        model.clearFilters()
        model.query = "ZZ"
        XCTAssertTrue(model.filteredLibrary.isEmpty, "ISIN search matches whole ISINs only")
        model.query = DemoUniverse.all[2].instrument.isin!.rawValue
        XCTAssertEqual(model.filteredLibrary.map(\.id), [DemoUniverse.all[2].instrument.id])
        model.query = ""
        model.sortOrder = .changeDescending
        let changes = model.filteredLibrary.compactMap { model.quotes[$0.id]?.value?.value.changePercent }
        XCTAssertEqual(changes, changes.sorted(by: >))
    }

    func testWatchlistToggleAndComparisonLimit() async throws {
        let app = try await demoApp()
        let model = MarketExplorerViewModel(app: app)
        await model.load()
        let id = DemoUniverse.all.last!.instrument.id
        XCTAssertFalse(model.library.first { $0.id == id }!.inWatchlist)
        await model.toggleWatchlist(id)
        XCTAssertTrue(model.library.first { $0.id == id }!.inWatchlist)
        for entry in model.library.prefix(6) { model.toggleCompare(entry.id) }
        XCTAssertEqual(model.compareSelection.count, MarketExplorerViewModel.maximumComparison)
    }

    func testAssetDetailsComputeExplainableStatistics() async throws {
        let app = try await demoApp()
        let demo = DemoUniverse.all.first { $0.instrument.kind == .stock }!
        let model = AssetDetailsViewModel(app: app, instrumentID: demo.instrument.id)
        await model.load()
        XCTAssertNotNil(model.quote?.value)
        XCTAssertTrue(model.hasHistory)
        XCTAssertLessThanOrEqual(model.chartPoints.count, AssetDetailsViewModel.maximumChartPoints + 1)
        XCTAssertNotNil(model.volatility?.value)
        XCTAssertEqual(model.volatility?.methodID, "M-VOL-1")
        XCTAssertNotNil(model.fundamentals?.value)
        model.setRange(.oneMonth)
        XCTAssertNil(model.volatility?.value, "one month (< 60 returns) is insufficient for volatility")
        XCTAssertNotNil(model.drawdown?.value)

        let bond = DemoUniverse.all.first { $0.bond != nil }!
        let bondModel = AssetDetailsViewModel(app: app, instrumentID: bond.instrument.id)
        await bondModel.load()
        XCTAssertNotNil(bondModel.bond)
        XCTAssertNil(bondModel.fundamentals, "stock fundamentals are not requested for bonds")
    }

    func testCompareRebasesToCommonStart() async throws {
        let app = try await demoApp()
        let ids = DemoUniverse.all.prefix(2).map(\.instrument.id)
        let model = CompareViewModel(app: app, instrumentIDs: Array(ids))
        await model.load()
        XCTAssertEqual(model.columns.count, 2)
        for column in model.columns {
            XCTAssertEqual(column.rebased.first?.value ?? 0, 100, accuracy: 1e-9)
        }
        XCTAssertEqual(model.columns[0].rebased.first?.date, model.columns[1].rebased.first?.date)
    }

    func testDataProvidersHiddenInDemo() async throws {
        let app = try await demoApp()
        let model = DataProvidersViewModel(app: app)
        await model.load()
        XCTAssertTrue(model.isDemo)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testProviderKeysAreStoredPerProfileAndRebuildRegistry() async throws {
        let context = try TestContext()
        let app = AppModel(environment: AppEnvironment(paths: context.paths, secureStore: context.secureStore,
                                                       biometricStore: context.biometrics,
                                                       passwordDerivation: Argon2idKeyDerivation.testing, clock: context.clock,
                                                       httpClient: OfflineHTTPClient()))
        await app.bootstrap()
        let create = CreateProfileViewModel(app: app)
        create.displayName = "P"; create.password = "Dlouhé heslo 2026!"; create.confirmation = "Dlouhé heslo 2026!"
        await create.submit()
        let profileID = try XCTUnwrap(app.session?.profileID)

        let model = DataProvidersViewModel(app: app)
        await model.load()
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(app.services?.registry.marketData.count, 0, "no keys → no market providers")
        XCTAssertEqual(Set(app.services?.registry.exchangeRates.map(\.info.id) ?? []), ["cnb", "ecb"])

        await model.saveKey("  secret-key  ", for: FinnhubProvider.id)
        let stored = try context.secureStore.data(service: .apiKey, account: "\(profileID.string)/finnhub")
        XCTAssertEqual(stored.map { String(decoding: $0, as: UTF8.self) }, "secret-key")
        XCTAssertEqual(app.services?.registry.marketData.map(\.info.id), [FinnhubProvider.id])
        XCTAssertTrue(app.preferences.providerSettings.contains { $0.id == FinnhubProvider.id && $0.enabled })

        await model.removeKey(for: FinnhubProvider.id)
        XCTAssertNil(try context.secureStore.data(service: .apiKey, account: "\(profileID.string)/finnhub"))
        XCTAssertEqual(app.services?.registry.marketData.count, 0)

        model.secContactEmail = "not an email"
        XCTAssertFalse(model.secEmailIsValid)
        model.secContactEmail = "me@example.com"
        await model.saveSECEmail()
        XCTAssertEqual(app.preferences.secContactEmail, "me@example.com")
        XCTAssertTrue(app.services?.registry.fundamentals.contains { $0.info.id == SECEdgarProvider.id } ?? false)
    }
}
