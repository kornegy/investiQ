import Charts
import SwiftUI
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQServices
import InvestiQPresentation

/// Asset details (spec §9–12). Shows source/freshness for every value and never fabricates charts.
struct AssetDetailView: View {
    let instrumentID: InstrumentID
    @Environment(AppModel.self) private var app
    @State private var model: AssetDetailsViewModel?
    @State private var analysis: AssetAnalysisViewModel?

    var body: some View {
        Group {
            if let model, let analysis {
                AssetDetailContent(model: model, analysis: analysis)
            } else {
                ProgressView()
            }
        }
        .task(id: instrumentID) {
            if model?.instrumentID != instrumentID {
                model = AssetDetailsViewModel(app: app, instrumentID: instrumentID)
                analysis = AssetAnalysisViewModel(app: app)
            }
            await model?.load()
            if let model { analysis?.update(from: model) }
        }
    }
}

private struct AssetDetailContent: View {
    @Bindable var model: AssetDetailsViewModel
    let analysis: AssetAnalysisViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let entry = model.entry {
                    AssetHeader(entry: entry, quote: model.quote, refresh: {
                        Task {
                            await model.load(forceRefresh: true)
                            analysis.update(from: model)
                        }
                    })
                }
                Picker("asset.range", selection: Binding(get: { model.range }, set: { model.setRange($0) })) {
                    ForEach(ChartRange.allCases) { Text(LocalizedStringKey("range.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                PriceChartCard(model: model)
                PerformanceCards(model: model)
                if model.entry?.instrument.kind == .stock { FundamentalsCard(outcome: model.fundamentals) }
                if let bond = model.bond { BondTermsCard(bond: bond) }
                if let etf = model.etf { ETFFactsCard(etf: etf) }
                AssetAnalysisCards(model: analysis, kind: model.entry?.instrument.kind)
                DataSourcesCard(model: model)
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
        .overlay(alignment: .topTrailing) { if model.isLoading { ProgressView().padding() } }
        .navigationTitle(model.entry?.instrument.name ?? "")
    }
}

private struct AssetHeader: View {
    let entry: InstrumentEntry
    let quote: DataOutcome<Quote>?
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(entry.instrument.name).font(.largeTitle.bold())
                Text(identifiers).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if let quote = quote?.value {
                    if entry.instrument.kind.isBond {
                        // Bond quotes are clean prices in percent of face value (market convention).
                        Text(L10n.string(Message("asset.bondQuote", [.decimal(quote.value.price, fractionDigits: 2)])))
                            .font(.title.monospacedDigit().bold())
                    } else {
                        Text(Formatters.money(Money(quote.value.price, quote.value.currency))).font(.title.monospacedDigit().bold())
                    }
                    if let change = quote.value.change, let percent = quote.value.changePercent {
                        ChangeLabel(direction: ChangeDirection(change),
                                    text: "\(Formatters.decimal(change)) (\(Formatters.percent((percent / 100).doubleValue)))")
                    }
                    SourceFooter(metadata: quote.metadata)
                    if quote.metadata.quality == .conflicting, let other = quote.metadata.conflicts.first {
                        Text(L10n.string(.init("asset.conflict", [.text(other.source.name), .decimal(other.value, fractionDigits: 2)])))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("asset.noQuote").foregroundStyle(.secondary)
                }
                Button("asset.refresh", action: refresh).controlSize(.small)
            }
        }
    }

    private var identifiers: String {
        var parts = [L10n.string("instrument.kind.\(entry.instrument.kind.rawValue)")]
        if let listing = entry.listing {
            parts.append(listing.ticker.rawValue)
            if let mic = listing.mic { parts.append(mic.rawValue) }
            parts.append(listing.tradingCurrency.rawValue)
        }
        if let isin = entry.instrument.isin { parts.append("ISIN \(isin.rawValue)") }
        return parts.joined(separator: " · ")
    }
}

private struct PriceChartCard: View {
    let model: AssetDetailsViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "asset.chart.title", help: "asset.chart.help")
                if model.hasHistory {
                    Chart(model.chartPoints) { point in
                        LineMark(x: .value("date", point.date), y: .value("price", point.value))
                            .interpolationMethod(.linear)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 240)
                    .accessibilityLabel(Text("asset.chart.title"))
                    if let history = model.history?.value {
                        SourceFooter(metadata: history.metadata)
                        if history.value.adjustment == .unadjusted {
                            Text("asset.chart.unadjusted").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    // No fabricated charts (spec §8): say clearly that history is missing.
                    ContentUnavailableView("chart.noHistory", systemImage: "chart.xyaxis.line", description: Text("chart.noHistory.detail"))
                }
            }
        }
    }
}

private struct PerformanceCards: View {
    let model: AssetDetailsViewModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.m)], spacing: Spacing.m) {
            MetricTile(title: "asset.metric.periodReturn", value: Formatters.percent(model.periodReturn),
                       change: model.periodReturn.map { (ChangeDirection(Decimal(finite: $0)), Formatters.percent($0)) },
                       help: "asset.metric.periodReturn.help")
            AnalyticTile(title: "asset.metric.volatility", help: "asset.metric.volatility.help", result: model.volatility, negate: false)
            AnalyticTile(title: "asset.metric.maxDrawdown", help: "asset.metric.maxDrawdown.help", result: model.drawdown, negate: true)
        }
    }
}

/// Shows an explainable analytical result: value, explanation, method ID, completeness, limitations.
struct AnalyticTile: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let result: AnalyticResult<Double>?
    let negate: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: title, help: help)
                Text(Formatters.percent(result?.value.map { negate ? -$0 : $0 })).font(.metricValue)
                if let explanation = result?.explanation {
                    Text(L10n.string(explanation)).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let result {
                    ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, limitation in
                        Text("• " + L10n.string(limitation)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(L10n.string(.init("analytics.methodFooter", [.text(result.methodID), .percent(result.completeness, fractionDigits: 0)])))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct FundamentalsCard: View {
    let outcome: DataOutcome<FundamentalsSnapshot>?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "asset.fundamentals.title", help: "asset.fundamentals.help")
                if let snapshot = outcome?.value {
                    let f = snapshot.value
                    let currency = f.currency
                    Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                        metric("metric.marketCap", Formatters.money(f.marketCapitalization, currency), help: "metric.marketCap.help")
                        metric("metric.revenue", Formatters.money(f.revenueTTM, currency), help: "metric.revenue.help")
                        metric("metric.revenueGrowth", Formatters.percent(f.revenueGrowthYoY?.doubleValue), help: "metric.revenueGrowth.help")
                        metric("metric.netIncome", Formatters.money(f.netIncomeTTM, currency), help: "metric.netIncome.help")
                        metric("metric.eps", Formatters.decimal(f.epsTTM), help: "metric.eps.help")
                        metric("metric.pe", f.epsTTM.map { $0 <= 0 } == true ? L10n.string("metric.notMeaningful") : Formatters.decimal(f.peRatio, fractionDigits: 1), help: "metric.pe.help")
                        metric("metric.pb", Formatters.decimal(f.pbRatio, fractionDigits: 1), help: "metric.pb.help")
                        metric("metric.fcf", Formatters.money(f.freeCashFlowTTM, currency), help: "metric.fcf.help")
                        metric("metric.debtToEquity", Formatters.decimal(f.debtToEquity), help: "metric.debtToEquity.help")
                        metric("metric.operatingMargin", Formatters.percent(f.operatingMargin?.doubleValue), help: "metric.operatingMargin.help")
                        metric("metric.dividendYield", Formatters.percent(f.dividendYield?.doubleValue), help: "metric.dividendYield.help")
                    }
                    SourceFooter(metadata: snapshot.metadata)
                    Text("asset.fundamentals.missingNote").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("asset.fundamentals.unavailable").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ key: LocalizedStringKey, _ value: String, help: LocalizedStringKey) -> some View {
        GridRow {
            HStack(spacing: Spacing.xs) { Text(key); InfoTooltip(text: help) }
            Text(value).font(.tableNumber)
        }
    }
}

struct BondTermsCard: View {
    let bond: BondDetails

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "bond.terms.title", help: "bond.terms.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                    row("bond.faceValue", Formatters.decimal(bond.faceValue))
                    row("bond.couponRate", Formatters.percent(bond.couponRate.doubleValue))
                    row("bond.couponFrequency", L10n.string("bond.frequency.\(bond.couponFrequency)"))
                    row("bond.maturity", Formatters.date(bond.maturityDate))
                    row("bond.rating", [bond.creditRating, bond.ratingAgency].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L10n.string("value.missing"))
                    row("bond.callable", L10n.string(bond.isCallable ? "common.yes" : "common.no"))
                    row("bond.minimumDenomination", Formatters.decimal(bond.minimumDenomination))
                }
            }
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow { Text(key); Text(value).font(.tableNumber) }
    }
}

struct ETFFactsCard: View {
    let etf: ETFDetails

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "etf.facts.title", help: "etf.facts.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                    row("etf.manager", etf.manager ?? L10n.string("value.missing"))
                    row("etf.index", etf.indexName ?? L10n.string("value.missing"))
                    row("etf.ter", Formatters.percent(etf.totalExpenseRatio?.doubleValue))
                    row("etf.replication", etf.replication.map { L10n.string("etf.replication.\($0.rawValue)") } ?? L10n.string("value.missing"))
                    row("etf.distribution", etf.distribution.map { L10n.string("etf.distribution.\($0.rawValue)") } ?? L10n.string("value.missing"))
                    row("etf.ucits", etf.isUCITS.map { L10n.string($0 ? "common.yes" : "common.no") } ?? L10n.string("value.missing"))
                    row("etf.domicile", etf.domicile ?? L10n.string("value.missing"))
                }
                Text("etf.currencyNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow { Text(key); Text(value).font(.tableNumber) }
    }
}

private struct DataSourcesCard: View {
    let model: AssetDetailsViewModel

    var body: some View {
        let failures = (model.quote?.failures ?? []) + (model.history?.failures ?? []) + (model.fundamentals?.failures ?? [])
        if !failures.isEmpty || model.quote?.isStale == true {
            Card {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    CardHeader(title: "asset.dataIssues.title")
                    if model.quote?.isStale == true { Text("asset.dataIssues.stale").font(.callout) }
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        Text(L10n.string(.init("market.providerFailed", [.text(failure.providerID),
                                                                          .key("provider.failure.\(ProviderFailureKey.key(failure.failure))")])))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
