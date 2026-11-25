import Foundation
import Observation
import InvestiQCore
import InvestiQServices

/// Portfolio section: portfolios (real and virtual kept apart), holdings, transactions, CSV export.
@MainActor
@Observable
public final class PortfolioViewModel {
    public var kind: PortfolioKind = .real
    public private(set) var portfolios: [Portfolio] = []
    public var selectedPortfolioID: PortfolioID?
    public private(set) var snapshot: PortfolioSnapshot?
    public private(set) var transactions: [Transaction] = []
    public private(set) var error: Message?
    public private(set) var isLoading = false

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    /// Minors use educational mode: only virtual portfolios (spec §7).
    public var realPortfoliosAllowed: Bool { !app.educationalMode }

    public func load() async {
        guard let services = app.services else { return }
        if !realPortfoliosAllowed { kind = .virtual }
        isLoading = true
        defer { isLoading = false }
        do {
            portfolios = try await services.portfolios.portfolios(kind: kind)
            if selectedPortfolioID == nil || !portfolios.contains(where: { $0.id == selectedPortfolioID }) {
                selectedPortfolioID = portfolios.first?.id
            }
            try await reloadSelected()
            error = nil
        } catch {
            self.error = Message("portfolio.error.loadFailed")
        }
    }

    public func reloadSelected() async throws {
        guard let services = app.services, let id = selectedPortfolioID else {
            snapshot = nil
            transactions = []
            return
        }
        transactions = try await services.portfolios.transactions(id).sorted { ($0.tradeDate, $0.createdAt) > ($1.tradeDate, $1.createdAt) }
        snapshot = try await services.portfolios.snapshot(id)
    }

    public func select(_ id: PortfolioID?) async {
        selectedPortfolioID = id
        do { try await reloadSelected() } catch { self.error = Message("portfolio.error.loadFailed") }
    }

    public func createPortfolio(name: String, baseCurrency: CurrencyCode) async {
        guard let services = app.services else { return }
        let targetKind: PortfolioKind = realPortfoliosAllowed ? kind : .virtual
        do {
            let created = try await services.portfolios.createPortfolio(name: name, kind: targetKind, baseCurrency: baseCurrency)
            selectedPortfolioID = created.id
            await load()
        } catch PortfolioServiceError.invalidName {
            error = Message("portfolio.error.invalidName")
        } catch {
            self.error = Message("portfolio.error.nameTaken")
        }
    }

    public func deleteSelectedPortfolio() async {
        guard let services = app.services, let id = selectedPortfolioID else { return }
        do {
            try await services.portfolios.deletePortfolio(id)
            selectedPortfolioID = nil
            await load()
        } catch {
            self.error = Message("portfolio.error.deleteFailed")
        }
    }

    public func delete(_ transaction: Transaction) async {
        guard let services = app.services else { return }
        do {
            try await services.portfolios.delete(transaction)
            try await reloadSelected()
            error = nil
        } catch PortfolioServiceError.ledger {
            error = Message("portfolio.error.deleteBreaksLedger")
        } catch {
            self.error = Message("portfolio.error.deleteFailed")
        }
    }

    public func exportCSV() async -> String? {
        guard let services = app.services, let id = selectedPortfolioID else { return nil }
        return try? await services.portfolios.exportCSV(id)
    }

    public func instrumentName(_ id: InstrumentID?) -> String? {
        id.flatMap { snapshot?.instruments[$0]?.name }
    }
}
