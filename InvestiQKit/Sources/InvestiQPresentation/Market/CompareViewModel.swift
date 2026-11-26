import Foundation
import Observation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQServices

/// Side-by-side comparison of up to four instruments over a common window (spec §9).
@MainActor
@Observable
public final class CompareViewModel {
    public struct Column: Sendable, Identifiable {
        public var id: InstrumentID
        public var name: String
        public var currency: CurrencyCode
        public var kind: InstrumentKind
        /// Prices rebased to 100 at the first common date.
        public var rebased: [ChartPoint]
        public var periodReturn: Double?
        public var volatility: Double?
        public var maxDrawdown: Double?
        public var source: DataSourceInfo?
        public var delay: DelayStatus?
    }

    public private(set) var columns: [Column] = []
    public private(set) var isLoading = false
    public var range: ChartRange = .oneYear
    private let app: AppModel
    private let ids: [InstrumentID]

    public init(app: AppModel, instrumentIDs: [InstrumentID]) {
        self.app = app
        self.ids = instrumentIDs
    }

    public func load() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        let today = app.environment.clock.today()
        let start = range.start(endingAt: today)
        var loaded: [(InstrumentEntry, Sourced<PriceSeries>?)] = []
        for id in ids {
            guard let entry = try? await services.instruments.entry(id), let listing = entry.listing else { continue }
            let outcome = await services.marketData.history(for: listing, range: DateRange(start: start, end: today))
            loaded.append((entry, outcome.value))
        }
        // Common window: from the latest first date among all series (no extrapolation).
        let commonStart = loaded.compactMap { $0.1?.value.firstDate }.max() ?? start
        columns = loaded.map { entry, sourced in
            let bars = sourced?.value.bars.filter { $0.date >= commonStart } ?? []
            let base = bars.first?.close.doubleValue
            let rebased: [ChartPoint] = base.map { base in
                bars.map { ChartPoint(date: $0.date.startOfDay(in: TimeZone(identifier: "UTC") ?? .current), value: $0.close.doubleValue / base * 100) }
            } ?? []
            let series = sourced.map { s in s.value.withBars(bars) }
            return Column(id: entry.id, name: entry.instrument.name, currency: entry.listing?.tradingCurrency ?? entry.instrument.currency,
                          kind: entry.instrument.kind, rebased: rebased, periodReturn: series.flatMap(Performance.totalReturn),
                          volatility: series.flatMap(Performance.annualizedVolatility),
                          maxDrawdown: series.flatMap(Performance.maximumDrawdown)?.depth,
                          source: sourced?.metadata.source, delay: sourced?.metadata.delay)
        }
    }
}

extension PriceSeries {
    func withBars(_ newBars: [PriceBar]) -> PriceSeries {
        var copy = self
        copy.bars = newBars
        return copy
    }
}
