import Charts
import SwiftUI
import InvestiQCore
import InvestiQServices
import InvestiQPresentation

/// Overview / dashboard (spec §8).
struct OverviewView: View {
    @Environment(AppModel.self) private var app
    @State private var model: OverviewViewModel?

    var body: some View {
        Group {
            if let model { OverviewContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = OverviewViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct OverviewContent: View {
    @Bindable var model: OverviewViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                if let error = model.error { InlineMessage(message: error) }
                if model.portfolios.isEmpty && !model.isLoading {
                    ContentUnavailableView {
                        Label("overview.empty.title", systemImage: "briefcase")
                    } description: {
                        Text("overview.empty.detail")
                    } actions: {
                        Button("overview.empty.action") { app.selectedSection = .portfolio }
                    }
                } else if let snapshot = model.snapshot {
                    MetricsGrid(valuation: snapshot.valuation)
                    ValueChartCard(model: model)
                    HStack(alignment: .top, spacing: Spacing.m) {
                        AllocationCard(title: "overview.allocation.type", slices: model.allocationByType, currency: model.baseCurrency)
                        AllocationCard(title: "overview.allocation.currency", slices: model.allocationByCurrency, currency: model.baseCurrency)
                    }
                    RiskNotesCard(notes: model.riskNotes)
                    FreshnessCard(valuation: snapshot.valuation)
                }
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
        .overlay(alignment: .topTrailing) { if model.isLoading { ProgressView().padding() } }
    }

    private var header: some View {
        HStack {
            Text("section.overview").font(.largeTitle.bold())
            Spacer()
            if model.portfolios.count > 1 {
                Picker("overview.portfolio", selection: Binding(get: { model.selectedPortfolioID }, set: { id in
                    model.selectedPortfolioID = id
                    Task { await model.load() }
                })) {
                    ForEach(model.portfolios) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 260)
            }
            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .help(Text("asset.refresh"))
        }
    }
}

private struct MetricsGrid: View {
    let valuation: PortfolioValuation

    var body: some View {
        let currency = valuation.baseCurrency
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.m)], spacing: Spacing.m) {
            MetricTile(title: "overview.metric.totalValue", value: Formatters.money(valuation.totalValueBase, currency),
                       help: "overview.metric.totalValue.help")
            MetricTile(title: "overview.metric.invested", value: Formatters.money(valuation.investedBase, currency),
                       help: "overview.metric.invested.help")
            MetricTile(title: "overview.metric.unrealized", value: Formatters.money(valuation.unrealizedBase, currency),
                       change: valuation.unrealizedBase.map { (ChangeDirection($0), Formatters.money($0, currency)) },
                       help: "overview.metric.unrealized.help")
            MetricTile(title: "overview.metric.realized", value: Formatters.money(valuation.realizedBase, currency),
                       help: "overview.metric.realized.help")
            MetricTile(title: "overview.metric.totalReturn", value: Formatters.percent(valuation.totalReturnFraction),
                       change: valuation.totalReturnBase.map { (ChangeDirection($0), Formatters.money($0, currency)) },
                       help: "overview.metric.totalReturn.help",
                       footnote: L10n.string("overview.returnBasis.\(valuation.returnBasis.rawValue)"))
            MetricTile(title: "overview.metric.dividends", value: Formatters.money(valuation.dividendsBase, currency),
                       help: "overview.metric.dividends.help")
            MetricTile(title: "overview.metric.coupons", value: Formatters.money(valuation.couponsBase, currency),
                       help: "overview.metric.coupons.help")
            MetricTile(title: "overview.metric.fees", value: Formatters.money(valuation.feesBase, currency),
                       help: "overview.metric.fees.help")
            MetricTile(title: "overview.metric.cash", value: Formatters.money(valuation.cashBase, currency),
                       help: "overview.metric.cash.help")
        }
    }
}

private struct ValueChartCard: View {
    let model: OverviewViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    CardHeader(title: "overview.chart.title", help: "overview.chart.help")
                    Picker("overview.chart.range", selection: Binding(get: { model.range }, set: { range in Task { await model.setRange(range) } })) {
                        ForEach(DashboardRange.allCases) { Text(LocalizedStringKey("dashboard.range.\($0.rawValue)")).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    .labelsHidden()
                }
                if model.hasChartData {
                    Chart(model.chartPoints) { point in
                        LineMark(x: .value("date", point.date), y: .value("value", point.value))
                        AreaMark(x: .value("date", point.date), y: .value("value", point.value)).opacity(0.08)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 220)
                    HStack(spacing: Spacing.l) {
                        if let change = model.rangeChange {
                            Text(L10n.string(.init("overview.chart.change", [.money(Money(change, model.baseCurrency))]))).font(.callout)
                        }
                        if let twr = model.performance?.timeWeightedReturn {
                            Text(L10n.string(.init("overview.chart.twr", [.percent(twr, fractionDigits: 2)]))).font(.callout)
                                .help(Text("overview.chart.twr.help"))
                        }
                        if let mwr = model.performance?.moneyWeightedReturn {
                            Text(L10n.string(.init("overview.chart.mwr", [.percent(mwr, fractionDigits: 2)]))).font(.callout)
                                .help(Text("overview.chart.mwr.help"))
                        }
                    }
                    if model.performance?.hasGaps == true { Text("overview.chart.gaps").font(.caption).foregroundStyle(.orange) }
                    Text("overview.chart.dailyNote").font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("chart.noHistory", systemImage: "chart.xyaxis.line", description: Text("chart.noHistory.detail"))
                }
            }
        }
    }
}

struct AllocationCard: View {
    let title: LocalizedStringKey
    let slices: [AllocationSlice]
    let currency: CurrencyCode

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: title)
                if slices.isEmpty {
                    Text("value.missing").foregroundStyle(.secondary)
                } else {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("value", slice.weight), innerRadius: .ratio(0.6))
                            .foregroundStyle(by: .value("label", label(slice)))
                    }
                    .frame(height: 160)
                    ForEach(slices) { slice in
                        HStack {
                            Text(label(slice))
                            Spacer()
                            Text(Formatters.percent(slice.weight, fractionDigits: 1)).font(.tableNumber)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func label(_ slice: AllocationSlice) -> String { slice.labelKey.map(L10n.string) ?? slice.label }
}

private struct RiskNotesCard: View {
    let notes: [PortfolioRiskNote]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "overview.risk.title", help: "overview.risk.help")
                if notes.isEmpty {
                    Text("overview.risk.none").foregroundStyle(.secondary)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Label(text(note), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    private func text(_ note: PortfolioRiskNote) -> String {
        switch note {
        case .singlePositionConcentration(let name, let weight):
            return L10n.string(.init("overview.risk.position", [.text(name), .percent(weight, fractionDigits: 0)]))
        case .currencyConcentration(let currency, let weight):
            return L10n.string(.init("overview.risk.currency", [.text(currency.rawValue), .percent(weight, fractionDigits: 0)]))
        case .missingPrices(let count):
            return L10n.string(.init("overview.risk.missingPrices", [.integer(count)]))
        case .missingRates(let currencies):
            return L10n.string(.init("overview.risk.missingRates", [.text(currencies.map(\.rawValue).joined(separator: ", "))]))
        case .negativeCash(let currency):
            return L10n.string(.init("overview.risk.negativeCash", [.text(currency.rawValue)]))
        case .staleData:
            return L10n.string("overview.risk.stale")
        }
    }
}

private struct FreshnessCard: View {
    let valuation: PortfolioValuation

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let delay = valuation.worstDelay { FreshnessBadge(delay: delay) }
            if let oldest = valuation.oldestPriceTimestamp {
                Text(L10n.string(.init("overview.freshness.oldest", [.instant(oldest)]))).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
