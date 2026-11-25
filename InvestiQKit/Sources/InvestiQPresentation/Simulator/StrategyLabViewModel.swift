import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// Strategy lab (spec §22 "test different asset allocation strategies"): fixed-weight back-tests with costs,
/// compared with a single-instrument benchmark. Results describe the past only.
@MainActor
@Observable
public final class StrategyLabViewModel {
    public struct Row: Identifiable, Sendable, Hashable {
        public var id = UUID()
        public var instrumentID: InstrumentID?
        public var weightText: String
    }

    public var rows: [Row] = [Row(instrumentID: nil, weightText: "60"), Row(instrumentID: nil, weightText: "40")]
    public var initialText = "100000"
    public var monthlyText = "2000"
    public var start: Date
    public var end: Date
    public var rebalancing: StrategyBacktest.Rebalancing = .annually
    public var benchmarkID: InstrumentID?
    public private(set) var library: [InstrumentEntry] = []
    public private(set) var strategy: StrategyBacktest.Result?
    public private(set) var benchmark: StrategyBacktest.Result?
    public private(set) var isRunning = false
    public private(set) var error: Message?

    private let app: AppModel
    private let locale: Locale

    public init(app: AppModel, locale: Locale = .current) {
        self.app = app
        self.locale = locale
        let today = app.environment.clock.today()
        start = today.adding(years: -10).startOfDay(in: .current)
        end = today.startOfDay(in: .current)
    }

    public func load() async {
        guard let services = app.services else { return }
        do {
            library = try await services.instruments.library()
            let etfs = library.filter { $0.instrument.kind == .etf }
            if rows[0].instrumentID == nil { rows[0].instrumentID = etfs.first?.id }
            if rows.count > 1, rows[1].instrumentID == nil { rows[1].instrumentID = etfs.last?.id }
            if benchmarkID == nil { benchmarkID = etfs.first?.id }
        } catch {
            self.error = Message("simulator.error.loadFailed")
        }
    }

    public func addRow() { rows.append(Row(instrumentID: nil, weightText: "0")) }
    public func removeRow(_ row: Row) { rows.removeAll { $0.id == row.id } }

    public var weightSum: Decimal {
        rows.compactMap { DecimalSupport.parse($0.weightText, locale: locale) }.reduce(0, +)
    }

    public func run() async {
        guard let services = app.services else { return }
        var weights: [(InstrumentID, Double)] = []
        for row in rows {
            guard let id = row.instrumentID, let weight = DecimalSupport.parse(row.weightText, locale: locale), weight >= 0 else {
                error = Message("strategy.error.invalidRow")
                return
            }
            if weight > 0 { weights.append((id, (weight / 100).doubleValue)) }
        }
        guard weightSum == 100 else { error = Message("strategy.error.weights"); return }
        guard let initial = DecimalSupport.parse(initialText, locale: locale), initial > 0,
              let monthly = DecimalSupport.parse(monthlyText, locale: locale), monthly >= 0 else {
            error = Message("strategy.error.amounts")
            return
        }
        let from = LocalDate(start, timeZone: .current), to = LocalDate(end, timeZone: .current)
        guard from < to else { error = Message("strategy.error.period"); return }
        isRunning = true
        defer { isRunning = false }
        do {
            let request = SimulatorService.StrategyRequest(weights: weights, initial: initial.doubleValue, monthly: monthly.doubleValue,
                                                           start: from, end: to, rebalancing: rebalancing, fees: .standard,
                                                           baseCurrency: app.preferences.baseCurrency, benchmark: benchmarkID)
            let result = try await services.simulator.backtest(request)
            strategy = result.strategy
            benchmark = result.benchmark
            error = nil
        } catch StrategyBacktest.BacktestError.noPriceAtStart(let name) {
            error = Message("strategy.error.noPriceAtStart", [.text(name)])
        } catch {
            strategy = nil
            benchmark = nil
            self.error = Message("strategy.error.failed")
        }
    }

    public var baseCurrency: CurrencyCode { app.preferences.baseCurrency }

    public func name(_ id: InstrumentID?) -> String { library.first { $0.id == id }?.instrument.name ?? "" }
}
