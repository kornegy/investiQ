import Charts
import SwiftUI
import InvestiQCore
import InvestiQAnalytics
import InvestiQPresentation

/// Risk & scenarios (spec §13–14): ten risk categories, exposures, hypothetical stress tests and the
/// public forecast accuracy record. Nothing here is a recommendation.
struct RiskView: View {
    @Environment(AppModel.self) private var app
    @State private var model: RiskViewModel?

    var body: some View {
        Group {
            if let model { RiskContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = RiskViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct RiskContent: View {
    @Bindable var model: RiskViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Text("section.risk").font(.largeTitle.bold())
                    Spacer()
                    if model.portfolios.count > 1 {
                        Picker("risk.portfolio", selection: Binding(get: { model.selectedPortfolioID },
                                                                     set: { id in if let id { Task { await model.select(id) } } })) {
                            ForEach(model.portfolios) { portfolio in
                                Text(portfolio.kind == .virtual ? L10n.string(Message("risk.portfolio.virtual", [.text(portfolio.name)]))
                                                                : portfolio.name)
                                    .tag(Optional(portfolio.id))
                            }
                        }
                        .frame(maxWidth: 280)
                    }
                }
                Picker("risk.tabs", selection: $model.tab) {
                    ForEach(RiskTab.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let error = model.error { InlineMessage(message: error) }
                switch model.tab {
                case .forecasts:
                    ForecastAccuracyView()
                default:
                    if model.hasHoldings, let report = model.report {
                        switch model.tab {
                        case .categories: CategoriesTab(model: model, report: report)
                        case .exposures: ExposuresTab(report: report, base: model.baseCurrency)
                        case .stress: StressTab(model: model)
                        case .forecasts: EmptyView()
                        }
                    } else if !model.isLoading {
                        ContentUnavailableView("risk.empty.title", systemImage: "exclamationmark.shield",
                                               description: Text("risk.empty.description"))
                    }
                }
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
        .overlay(alignment: .topTrailing) { if model.isLoading { ProgressView().padding() } }
    }
}

private struct CategoriesTab: View {
    let model: RiskViewModel
    let report: PortfolioRiskReport

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.m)], spacing: Spacing.m) {
                MetricTile(title: "risk.metric.volatility", value: Formatters.percent(report.annualVolatility, fractionDigits: 1),
                           help: "risk.metric.volatility.help")
                MetricTile(title: "risk.metric.var95", value: Formatters.percent(report.valueAtRisk95, fractionDigits: 2),
                           help: "risk.metric.var95.help")
                MetricTile(title: "risk.metric.cvar95", value: Formatters.percent(report.conditionalVaR95, fractionDigits: 2),
                           help: "risk.metric.cvar95.help")
                MetricTile(title: "risk.metric.effectivePositions",
                           value: Formatters.decimal(report.effectivePositions.flatMap { Decimal(finite: $0) }, fractionDigits: 1),
                           help: "risk.metric.effectivePositions.help")
                MetricTile(title: "risk.metric.duration",
                           value: Formatters.decimal(report.weightedModifiedDuration.flatMap { Decimal(finite: $0) }, fractionDigits: 2),
                           help: "risk.metric.duration.help")
            }
            ForEach(model.sortedCategories, id: \.category) { assessment in
                Card {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(L10n.key("risk.category", assessment.category.rawValue)).font(.headline)
                            Spacer()
                            RiskLevelBadge(level: assessment.level)
                        }
                        Text(L10n.string(assessment.explanation)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if assessment.isQualitative {
                            Text("risk.qualitative").font(.caption).foregroundStyle(.secondary)
                        }
                        AIExplainButton(title: "ai.explainRisk",
                                        task: .explainRisk(category: L10n.string("risk.category.\(assessment.category.rawValue)"),
                                                           level: L10n.string("risk.level.\(assessment.level.rawValue)")))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("risk.methodNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RiskLevelBadge: View {
    @Environment(\.palette) private var palette
    let level: RiskLevel

    var body: some View {
        Label(L10n.key("risk.level", level.rawValue), systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // Level is conveyed by text and symbol as well as colour (accessibility).
    private var symbol: String {
        switch level {
        case .low: return "circle"
        case .moderate: return "circle.lefthalf.filled"
        case .elevated: return "exclamationmark.circle"
        case .high: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch level {
        case .low, .moderate: return palette.info
        case .elevated, .high: return palette.warning
        case .unknown: return .secondary
        }
    }
}

private struct ExposuresTab: View {
    let report: PortfolioRiskReport
    let base: CurrencyCode

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ExposureCard(title: "risk.exposure.assetType", items: report.byAssetType, base: base, label: assetTypeLabel)
            ExposureCard(title: "risk.exposure.issuer", items: report.byIssuer, base: base, label: { $0 })
            ExposureCard(title: "risk.exposure.sector", items: report.bySector, base: base, label: { $0 })
            ExposureCard(title: "risk.exposure.country", items: report.byCountry, base: base, label: { $0 })
            ExposureCard(title: "risk.exposure.currency", items: report.byCurrency, base: base, label: currencyLabel)
            if !report.correlations.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        CardHeader(title: "risk.correlations.title", help: "risk.correlations.help")
                        ForEach(Array(report.correlations.prefix(10).enumerated()), id: \.offset) { _, pair in
                            HStack {
                                Text(verbatim: "\(pair.first) · \(pair.second)").lineLimit(1)
                                Spacer()
                                Text(Formatters.decimal(Decimal(finite: pair.correlation), fractionDigits: 2)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func assetTypeLabel(_ raw: String) -> String {
        raw == "bondETF" ? L10n.string("risk.assetType.bondETF") : L10n.string("instrument.kind.\(raw)")
    }

    private func currencyLabel(_ raw: String) -> String { RiskLabels.exposure(raw) }
}

/// Localises engine labels such as `cash:CZK`; other labels (issuers, countries, codes) are data.
enum RiskLabels {
    @MainActor
    static func exposure(_ raw: String) -> String {
        guard raw.hasPrefix(RiskEngine.cashLabelPrefix) else { return raw }
        return L10n.string(Message("risk.exposure.cash", [.text(String(raw.dropFirst(RiskEngine.cashLabelPrefix.count)))]))
    }
}

private struct ExposureCard: View {
    let title: LocalizedStringKey
    let items: [ExposureItem]
    let base: CurrencyCode
    let label: (String) -> String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: title)
                Chart(items.prefix(12)) { item in
                    BarMark(x: .value("weight", item.weight), y: .value("label", label(item.label)))
                        .annotation(position: .trailing) {
                            Text(Formatters.percent(item.weight, fractionDigits: 1)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(max(1, min(items.count, 12))) * 26 + 10)
                .accessibilityLabel(Text(title))
            }
        }
    }
}

private struct StressTab: View {
    let model: RiskViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("stress.banner", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.orange.opacity(0.12)))
            ForEach(StressPreset.allCases) { preset in
                if let result = model.stressResults[preset] {
                    StressCard(preset: preset, result: result, base: model.baseCurrency,
                               issuer: preset.needsIssuer ? model.largestIssuer?.label : nil)
                }
            }
        }
    }
}

private struct StressCard: View {
    let preset: StressPreset
    let result: RiskEngine.StressResult
    let base: CurrencyCode
    let issuer: String?
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(preset.titleKey)).font(.headline)
                        if let issuer { Text(issuer).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatters.money(Decimal(finite: result.changeBase), base)).font(.title3.monospacedDigit())
                        Text(Formatters.percent(result.changeFraction, fractionDigits: 1)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("stress.details", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                            HStack {
                                Text(RiskLabels.exposure(line.name)).lineLimit(1)
                                if line.usedAssumption { Text("stress.assumed").font(.caption2).foregroundStyle(.orange) }
                                Spacer()
                                Text(Formatters.money(Decimal(finite: line.changeBase), base)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                        ForEach(Array(result.assumptions.enumerated()), id: \.offset) { _, assumption in
                            Text(L10n.string(assumption)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
            }
        }
    }
}
