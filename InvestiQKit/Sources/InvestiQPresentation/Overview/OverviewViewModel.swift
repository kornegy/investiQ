import Foundation
import Observation
import InvestiQCore
import InvestiQServices

/// Dashboard ranges required by spec §8. Data is daily: 1D/3D compare the latest daily closes.
public enum DashboardRange: String, CaseIterable, Sendable, Identifiable {
    case oneDay, threeDays, oneWeek, oneMonth, threeMonths, oneYear, all
    public var id: String { rawValue }

    public func start(endingAt end: LocalDate) -> LocalDate? {
        switch self {
        case .oneDay: return end.adding(days: -1)
        case .threeDays: return end.adding(days: -3)
        case .oneWeek: return end.adding(days: -7)
        case .oneMonth: return end.adding(months: -1)
        case .threeMonths: return end.adding(months: -3)
        case .oneYear: return end.adding(years: -1)
        case .all: return nil
        }
    }
}

public struct AllocationSlice: Sendable, Identifiable, Hashable {
    public var id: String { label }
    public var label: String
    /// Localisation key when the label is a category (asset type), otherwise `nil` (currency code etc.).
    public var labelKey: String?
    public var value: Decimal
    public var weight: Double
}

/// Educational risk notes for the dashboard (rules in docs/FINANCIAL_METHODOLOGY.md §3 M-CON-1).
public enum PortfolioRiskNote: Hashable, Sendable {
    case singlePositionConcentration(name: String, weight: Double)
    case currencyConcentration(CurrencyCode, weight: Double)
    case missingPrices(count: Int)
    case missingRates([CurrencyCode])
    case negativeCash(CurrencyCode)
    case staleData
}

@MainActor
@Observable
public final class OverviewViewModel {
    public private(set) var portfolios: [Portfolio] = []
    public var selectedPortfolioID: PortfolioID?
    public var range: DashboardRange = .oneYear
    public private(set) var snapshot: PortfolioSnapshot?
    public private(set) var performance: PerformanceSeries?
    public private(set) var isLoading = false
    public private(set) var error: Message?

    /// Single-position weight above which a concentration note is shown (M-CON-1).
    public static let positionConcentrationThreshold = 0.20
    /// Share of non-base currencies above which a currency note is shown (M-CON-1).
    public static let currencyConcentrationThreshold = 0.50

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var baseCurrency: CurrencyCode { snapshot?.portfolio.baseCurrency ?? app.preferences.baseCurrency }

    public func load() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            portfolios = try await services.portfolios.portfolios(kind: .real)
            if selectedPortfolioID == nil || !portfolios.contains(where: { $0.id == selectedPortfolioID }) {
                selectedPortfolioID = portfolios.first?.id
            }
            guard let id = selectedPortfolioID else { snapshot = nil; performance = nil; return }
            snapshot = try await services.portfolios.snapshot(id)
            await loadPerformance()
            error = nil
        } catch {
            self.error = Message("overview.error.loadFailed")
        }
    }

    public func setRange(_ newRange: DashboardRange) async {
        range = newRange
        await loadPerformance()
    }

    private func loadPerformance() async {
        guard let services = app.services, let id = selectedPortfolioID else { return }
        let today = app.environment.clock.today()
        performance = try? await services.portfolios.performance(id, from: range.start(endingAt: today), to: today)
    }

    public var chartPoints: [ChartPoint] {
        (performance?.points ?? []).compactMap { point in
            point.value.map { ChartPoint(date: point.date.startOfDay(in: TimeZone(identifier: "UTC") ?? .current), value: $0.doubleValue) }
        }
    }

    /// True when fewer than two valued points exist — the chart then shows "no historical data".
    public var hasChartData: Bool { chartPoints.count >= 2 }

    public var allocationByType: [AllocationSlice] {
        guard let snapshot else { return [] }
        var totals: [String: Decimal] = [:]
        for holding in snapshot.valuation.holdings {
            guard let value = holding.marketValueBase else { continue }
            let kind = snapshot.instruments[holding.position.key.instrumentID]?.kind.rawValue ?? "unknown"
            totals[kind, default: 0] += value
        }
        if snapshot.ledger.tracksCash, let cash = snapshot.valuation.cashBase, cash > 0 { totals["cash", default: 0] += cash }
        return slices(totals, keyPrefix: "allocation.type.")
    }

    public var allocationByCurrency: [AllocationSlice] {
        guard let snapshot else { return [] }
        var totals: [String: Decimal] = [:]
        for holding in snapshot.valuation.holdings {
            guard let value = holding.marketValueBase else { continue }
            totals[holding.position.key.currency.rawValue, default: 0] += value
        }
        return slices(totals, keyPrefix: nil)
    }

    private func slices(_ totals: [String: Decimal], keyPrefix: String?) -> [AllocationSlice] {
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return [] }
        return totals.map { entry in
            AllocationSlice(label: entry.key, labelKey: keyPrefix.map { $0 + entry.key }, value: entry.value,
                            weight: (entry.value / sum).doubleValue)
        }
        .sorted { $0.value > $1.value }
    }

    public var riskNotes: [PortfolioRiskNote] {
        guard let snapshot else { return [] }
        var notes: [PortfolioRiskNote] = []
        for holding in snapshot.valuation.holdings {
            if let weight = holding.weight, weight > Self.positionConcentrationThreshold {
                let name = snapshot.instruments[holding.position.key.instrumentID]?.name ?? "?"
                notes.append(.singlePositionConcentration(name: name, weight: weight))
            }
        }
        for slice in allocationByCurrency where slice.label != baseCurrency.rawValue && slice.weight > Self.currencyConcentrationThreshold {
            if let code = CurrencyCode(rawValue: slice.label) { notes.append(.currencyConcentration(code, weight: slice.weight)) }
        }
        if !snapshot.valuation.missingPrices.isEmpty { notes.append(.missingPrices(count: snapshot.valuation.missingPrices.count)) }
        if !snapshot.valuation.missingRates.isEmpty { notes.append(.missingRates(snapshot.valuation.missingRates)) }
        for warning in snapshot.ledger.warnings {
            if case .negativeCash(let currency, _) = warning { notes.append(.negativeCash(currency)) }
        }
        if snapshot.valuation.worstDelay == .stale { notes.append(.staleData) }
        return notes
    }

    /// Value change over the selected range (first → last valued point), excluding flows.
    public var rangeChange: Decimal? {
        guard let points = performance?.points.filter({ $0.value != nil }), let first = points.first?.value, let last = points.last?.value,
              points.count >= 2 else { return nil }
        let flows = points.dropFirst().reduce(Decimal(0)) { $0 + $1.inflow - $1.outflow }
        return last - first - flows
    }
}
