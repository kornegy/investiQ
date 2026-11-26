import Foundation
import Observation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQServices

public enum ChartRange: String, CaseIterable, Sendable, Identifiable {
    case oneMonth, threeMonths, sixMonths, oneYear, fiveYears, all
    public var id: String { rawValue }

    public func start(endingAt end: LocalDate) -> LocalDate {
        switch self {
        case .oneMonth: return end.adding(months: -1)
        case .threeMonths: return end.adding(months: -3)
        case .sixMonths: return end.adding(months: -6)
        case .oneYear: return end.adding(years: -1)
        case .fiveYears: return end.adding(years: -5)
        case .all: return end.adding(years: -30)
        }
    }
}

public struct ChartPoint: Sendable, Hashable, Identifiable {
    public var date: Date
    public var value: Double
    public var id: Date { date }
}

/// Asset details (spec §9–12): quote, history chart, performance statistics, fundamentals,
/// bond/ETF data and sources. Values are never invented; missing data stays missing.
@MainActor
@Observable
public final class AssetDetailsViewModel {
    public let instrumentID: InstrumentID
    public private(set) var entry: InstrumentEntry?
    public private(set) var quote: DataOutcome<Quote>?
    public private(set) var history: DataOutcome<PriceSeries>?
    public private(set) var fundamentals: DataOutcome<FundamentalsSnapshot>?
    public private(set) var bond: BondDetails?
    public private(set) var etf: ETFDetails?
    public private(set) var volatility: AnalyticResult<Double>?
    public private(set) var drawdown: AnalyticResult<Double>?
    public private(set) var periodReturn: Double?
    public private(set) var isLoading = false
    public var range: ChartRange = .oneYear

    /// Charts render at most this many points (downsampled) for performance.
    public static let maximumChartPoints = 500
    private let app: AppModel

    public init(app: AppModel, instrumentID: InstrumentID) {
        self.app = app
        self.instrumentID = instrumentID
    }

    public func load(forceRefresh: Bool = false) async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        entry = try? await services.instruments.entry(instrumentID)
        guard let entry, let listing = entry.listing else { return }
        bond = try? await services.instruments.bondDetails(instrumentID)
        etf = try? await services.instruments.etfDetails(instrumentID)
        async let quoteOutcome = services.marketData.quote(for: listing, forceRefresh: forceRefresh)
        async let historyOutcome = services.marketData.history(for: listing, range: fullRange, forceRefresh: forceRefresh)
        quote = await quoteOutcome
        history = await historyOutcome
        if entry.instrument.kind == .stock {
            fundamentals = await services.marketData.fundamentals(for: listing, forceRefresh: forceRefresh)
        }
        recomputeStatistics()
    }

    private var today: LocalDate { app.environment.clock.today() }
    private var fullRange: DateRange { DateRange(start: today.adding(years: -10), end: today) }

    public func setRange(_ newRange: ChartRange) {
        range = newRange
        recomputeStatistics()
    }

    /// Series restricted to the selected range.
    public var rangeSeries: Sourced<PriceSeries>? {
        guard let history = history?.value else { return nil }
        let start = range.start(endingAt: today)
        return history.map { series in
            var copy = series
            copy.bars = series.bars.filter { $0.date >= start }
            return copy
        }
    }

    private func recomputeStatistics() {
        guard let series = rangeSeries else {
            volatility = nil
            drawdown = nil
            periodReturn = nil
            return
        }
        let now = app.environment.clock.now()
        volatility = Performance.volatilityResult(series, now: now)
        drawdown = Performance.drawdownResult(series, now: now)
        periodReturn = Performance.totalReturn(series.value)
    }

    /// Downsampled points for Swift Charts; empty when no history exists (never fabricated).
    public var chartPoints: [ChartPoint] {
        guard let bars = rangeSeries?.value.bars, !bars.isEmpty else { return [] }
        let step = max(1, bars.count / Self.maximumChartPoints)
        var points: [ChartPoint] = []
        for (index, bar) in bars.enumerated() where index % step == 0 || index == bars.count - 1 {
            points.append(ChartPoint(date: bar.date.startOfDay(in: TimeZone(identifier: "UTC") ?? .current), value: bar.close.doubleValue))
        }
        return points
    }

    public var hasHistory: Bool { !(rangeSeries?.value.bars.isEmpty ?? true) }
}
