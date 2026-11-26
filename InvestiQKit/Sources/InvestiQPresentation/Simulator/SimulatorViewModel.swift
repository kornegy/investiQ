import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// Paper trading (spec §22). Calm by design: no rankings, streaks, rewards or prompts to trade more.
@MainActor
@Observable
public final class SimulatorViewModel {
    public private(set) var sessions: [SimulatorOverview] = []
    public var selectedID: PortfolioID?
    public private(set) var library: [InstrumentEntry] = []
    public private(set) var report: SimulatorReport?
    public private(set) var isLoading = false
    public private(set) var error: Message?

    // New session form.
    public var newName = ""
    public var newMode: SimulatorMode = .historical
    public var newCapitalText = "100000"
    public var newStartDate: Date
    public var newBenchmarkID: InstrumentID?

    // Order form.
    public var orderInstrumentID: InstrumentID?
    public var orderSide: OrderSide = .buy
    public var orderQuantityText = ""
    public private(set) var preview: OrderPreview?
    public private(set) var previewPrice: Sourced<Decimal>?
    public private(set) var orderMessage: Message?

    private let app: AppModel
    private let locale: Locale

    public init(app: AppModel, locale: Locale = .current) {
        self.app = app
        self.locale = locale
        newStartDate = app.environment.clock.today().adding(years: -2).startOfDay(in: .current)
    }

    public var selected: SimulatorOverview? { sessions.first { $0.portfolio.id == selectedID } }
    public var currency: CurrencyCode { selected?.session.currency ?? app.preferences.baseCurrency }

    public func load() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            library = try await services.instruments.library()
            sessions = try await services.simulator.sessions()
            if selectedID == nil || !sessions.contains(where: { $0.portfolio.id == selectedID }) { selectedID = sessions.first?.portfolio.id }
            if newBenchmarkID == nil { newBenchmarkID = library.first { $0.instrument.kind == .etf }?.id }
            await loadReport()
            error = nil
        } catch {
            self.error = Message("simulator.error.loadFailed")
        }
    }

    public func select(_ id: PortfolioID) async {
        selectedID = id
        preview = nil
        orderMessage = nil
        await loadReport()
    }

    func loadReport() async {
        guard let services = app.services, let id = selectedID else { report = nil; return }
        do {
            report = try await services.simulator.report(id)
        } catch {
            report = nil
            self.error = Self.message(for: error)
        }
    }

    /// `defaultName` (localised by the view) is used when the name field is empty.
    public func createSession(defaultName: String) async -> Bool {
        guard let services = app.services else { return false }
        guard let capital = DecimalSupport.parse(newCapitalText.trimmingCharacters(in: .whitespaces), locale: locale), capital > 0 else {
            error = Message("simulator.error.invalidCapital")
            return false
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultName : newName
        do {
            let overview = try await services.simulator.createSession(
                name: name, mode: newMode, startingCapital: capital, currency: app.preferences.baseCurrency,
                startDate: newMode == .historical ? LocalDate(newStartDate, timeZone: .current) : nil, benchmark: newBenchmarkID)
            sessions = try await services.simulator.sessions()
            selectedID = overview.portfolio.id
            newName = ""
            error = nil
            await loadReport()
            return true
        } catch {
            self.error = Self.message(for: error)
            return false
        }
    }

    // MARK: Orders

    private var orderQuantity: Decimal? {
        DecimalSupport.parse(orderQuantityText.trimmingCharacters(in: .whitespaces), locale: locale).flatMap { $0 > 0 ? $0 : nil }
    }

    public func updatePreview() async {
        guard let services = app.services, let id = selectedID, let instrumentID = orderInstrumentID, let quantity = orderQuantity else {
            preview = nil
            previewPrice = nil
            return
        }
        do {
            let (preview, price) = try await services.simulator.preview(id, instrumentID: instrumentID, side: orderSide, quantity: quantity)
            self.preview = preview
            previewPrice = price
            orderMessage = nil
        } catch {
            preview = nil
            orderMessage = Self.message(for: error)
        }
    }

    public func placeOrder() async {
        guard let services = app.services, let id = selectedID, let instrumentID = orderInstrumentID else { return }
        guard let quantity = orderQuantity else { orderMessage = Message("simulator.error.invalidQuantity"); return }
        do {
            try await services.simulator.place(id, instrumentID: instrumentID, side: orderSide, quantity: quantity)
            orderMessage = Message("simulator.order.done")
            orderQuantityText = ""
            preview = nil
            await loadReport()
        } catch {
            orderMessage = Self.message(for: error)
        }
    }

    /// Moves a historical session forward by `days` (never past today, never backwards).
    public func advance(days: Int) async {
        guard let services = app.services, let selected, selected.session.mode == .historical else { return }
        do {
            _ = try await services.simulator.advance(selected.portfolio.id, to: selected.session.simDate.adding(days: days))
            sessions = try await services.simulator.sessions()
            preview = nil
            await loadReport()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    public var canAdvance: Bool {
        guard let selected, selected.session.mode == .historical else { return false }
        return selected.session.simDate < app.environment.clock.today()
    }

    public var heldInstruments: [InstrumentEntry] {
        let held = Set(report?.snapshot.ledger.openPositions.map(\.key.instrumentID) ?? [])
        return library.filter { held.contains($0.id) }
    }

    /// Difference to the benchmark that received the same deposits (base currency).
    public var differenceToBenchmark: Decimal? {
        guard let value = report?.valueBase, let benchmark = report?.benchmarkValueBase else { return nil }
        return value - benchmark
    }

    static func message(for error: any Error) -> Message {
        switch error as? SimulatorError {
        case .invalidCapital?: return Message("simulator.error.invalidCapital")
        case .invalidStartDate?: return Message("simulator.error.invalidStartDate", [.integer(SimulatorService.minimumHistoricalLookbackDays)])
        case .noPrice?: return Message("simulator.error.noPrice")
        case .noExchangeRate(let currency)?: return Message("simulator.error.noRate", [.text(currency.rawValue)])
        case .insufficientCash(let available, _)?: return Message("simulator.error.insufficientCash", [.decimal(available, fractionDigits: 2)])
        case .insufficientQuantity(let available)?: return Message("simulator.error.insufficientQuantity", [.decimal(available, fractionDigits: 4)])
        case .cannotMoveBackwards?: return Message("simulator.error.backwards")
        case .instrumentNotTradable?: return Message("simulator.error.notTradable")
        default: return Message("simulator.error.generic")
        }
    }
}
