import SwiftUI
import InvestiQCore
import InvestiQAnalytics
import InvestiQPresentation

/// Analysis cards of the asset page (spec §10–14). Statuses are neutral; scenarios carry no
/// probabilities; forecasts always show intervals and their validation against a naive baseline.
struct AssetAnalysisCards: View {
    @Bindable var model: AssetAnalysisViewModel
    let kind: InstrumentKind?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let assessment = model.assessment {
                StatusCard(statuses: assessment.statuses, completeness: assessment.completeness)
                ThesisCard(assessment: assessment)
            }
            if let bond = model.bondAnalysis {
                StatusCard(statuses: bond.statuses, completeness: nil)
                BondAnalysisCard(analysis: bond)
            }
            if let etf = model.etfAnalysis {
                StatusCard(statuses: etf.statuses, completeness: nil)
                ETFAnalysisCard(analysis: etf)
            }
            ScenarioCard(model: model)
            ForecastValidationCard(model: model)
        }
    }
}

private struct StatusCard: View {
    let statuses: [TriggeredStatus]
    let completeness: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "analysis.status.title", help: "analysis.status.help")
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, triggered in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        StatusBadge(status: triggered.status)
                        Text(L10n.string(triggered.rule)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let completeness {
                    Text(L10n.string(Message("analysis.completeness", [.percent(completeness, fractionDigits: 0)])))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("analysis.status.notAdvice").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ThesisCard: View {
    let assessment: InstrumentAssessment

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "thesis.title", help: "thesis.help")
                MessageList(title: "thesis.section.for", messages: assessment.argumentsFor)
                MessageList(title: "thesis.section.against", messages: assessment.argumentsAgainst)
                MessageList(title: "thesis.section.pricedIn", messages: assessment.pricedIn)
                MessageList(title: "thesis.section.invalidation", messages: assessment.invalidationConditions)
                if !assessment.missingData.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("thesis.section.missing").font(.subheadline.weight(.semibold))
                        Text(assessment.missingData.map { L10n.string($0) }.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                MessageList(title: "thesis.section.questions", messages: assessment.guidingQuestions)
            }
        }
    }
}

private struct MessageList: View {
    let title: LocalizedStringKey
    let messages: [Message]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.subheadline.weight(.semibold))
            if messages.isEmpty {
                Text("thesis.none").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Label(L10n.string(message), systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                        .font(.callout)
                }
            }
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BondAnalysisCard: View {
    let analysis: InstrumentAnalyzer.BondAnalysis

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "bond.analysis.title", help: "bond.analysis.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                    row("bond.ytm", Formatters.percent(analysis.yieldToMaturity))
                    row("bond.currentYield", Formatters.percent(analysis.currentYield))
                    row("bond.yieldToCall", Formatters.percent(analysis.yieldToCall))
                    row("bond.accruedInterest", Formatters.decimal(Decimal(finite: analysis.accruedInterest), fractionDigits: 3))
                    row("bond.dirtyPrice", Formatters.decimal(Decimal(finite: analysis.dirtyPrice), fractionDigits: 3))
                    row("bond.yearsToMaturity", Formatters.decimal(Decimal(finite: analysis.yearsToMaturity), fractionDigits: 2))
                    row("bond.macaulay", Formatters.decimal(analysis.risk.flatMap { Decimal(finite: $0.macaulay) }, fractionDigits: 2))
                    row("bond.modified", Formatters.decimal(analysis.risk.flatMap { Decimal(finite: $0.modified) }, fractionDigits: 2))
                    row("bond.convexity", Formatters.decimal(analysis.risk.flatMap { Decimal(finite: $0.convexity) }, fractionDigits: 1))
                    row("bond.priceChange100bp", Formatters.percent(analysis.priceChangeFor100bp))
                    row("bond.investmentGrade", gradeText)
                }
                Text("bond.analysis.per100").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var gradeText: String {
        switch analysis.isInvestmentGrade {
        case true?: return L10n.string("common.yes")
        case false?: return L10n.string("common.no")
        case nil: return L10n.string("value.missing")
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct ETFAnalysisCard: View {
    let analysis: InstrumentAnalyzer.ETFAnalysis

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "etf.analysis.title", help: "etf.analysis.help")
                if let drag = analysis.costDragExample {
                    Text(L10n.string(Message("etf.analysis.costDrag", [.decimal(Decimal(finite: drag.withoutTER) ?? 0, fractionDigits: 0),
                                                                        .decimal(Decimal(finite: drag.withTER) ?? 0, fractionDigits: 0)])))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let foreign = analysis.foreignCurrencyShare {
                    Text(L10n.string(Message("etf.analysis.foreignCurrency", [.percent(foreign, fractionDigits: 0)]))).font(.callout)
                }
                Text(L10n.string(analysis.kidExpectation)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ScenarioCard: View {
    @Bindable var model: AssetAnalysisViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "scenario.title", help: "scenario.help")
                HStack {
                    Picker("scenario.horizon", selection: $model.scenarioHorizon) {
                        ForEach(ScenarioHorizon.allCases) { Text(LocalizedStringKey($0.labelKey)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    TextField("scenario.amount", value: $model.illustrationAmount, format: .number)
                        .frame(maxWidth: 140)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("scenario.amount"))
                }
                if let scenarios = model.scenarios {
                    HStack(spacing: Spacing.m) {
                        ForEach(scenarios, id: \.kind) { scenario in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(LocalizedStringKey("scenario.kind.\(scenario.kind.rawValue)")).font(.subheadline.weight(.semibold))
                                Text(Formatters.decimal(Decimal(finite: scenario.endValue), fractionDigits: 0)).font(.title3.monospacedDigit())
                                Text(Formatters.percent(scenario.periodReturn, fractionDigits: 1)).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("scenario.noProbabilities").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SensitivityGrid(cells: model.sensitivity)
                } else {
                    Text(L10n.string(Message("scenario.insufficientHistory", [.integer(model.observations),
                                                                              .integer(model.scenarioObservationsRequired)])))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SensitivityGrid: View {
    let cells: [ScenarioBuilder.SensitivityCell]

    var body: some View {
        let years = Array(Set(cells.map(\.years))).sorted()
        let rates = Array(Set(cells.map(\.annualReturn))).sorted()
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("scenario.sensitivity.title").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                GridRow {
                    Text("scenario.sensitivity.rate").foregroundStyle(.secondary)
                    ForEach(years, id: \.self) { Text(L10n.string(Message("scenario.sensitivity.years", [.integer($0)]))).foregroundStyle(.secondary) }
                }
                ForEach(rates, id: \.self) { rate in
                    GridRow {
                        Text(Formatters.percent(rate, fractionDigits: 1))
                        ForEach(years, id: \.self) { year in
                            let value = cells.first { $0.annualReturn == rate && $0.years == year }?.endValue
                            Text(Formatters.decimal(value.flatMap { Decimal(finite: $0) }, fractionDigits: 0)).monospacedDigit()
                        }
                    }
                }
            }
            .font(.caption)
            Text("scenario.sensitivity.note").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ForecastValidationCard: View {
    @Bindable var model: AssetAnalysisViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "forecast.title", help: "forecast.help")
                HStack {
                    Picker("forecast.model", selection: $model.forecastModel) {
                        ForEach(ForecastModelID.allCases, id: \.self) { Text(LocalizedStringKey("forecast.model.\($0.rawValue)")).tag($0) }
                    }
                    .frame(maxWidth: 260)
                    Picker("forecast.horizon", selection: $model.forecastHorizon) {
                        ForEach(ForecastHorizon.allCases) { Text(LocalizedStringKey($0.labelKey)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                HStack {
                    Button("forecast.validate") { Task { await model.runValidation() } }
                        .disabled(model.isValidating)
                    if model.isValidating { ProgressView().controlSize(.small) }
                    Button("forecast.record") { Task { await model.recordForecast() } }
                }
                if !model.validations.isEmpty {
                    ValidationTable(metrics: model.validations)
                } else if model.validationAttempted {
                    Text("forecast.validation.unavailable").font(.callout).foregroundStyle(.secondary)
                }
                if let message = model.forecastMessage {
                    InlineMessage(message: message)
                    if message.key == "forecast.error.staleInput" {
                        Button("forecast.recordAnyway") { Task { await model.recordForecast(allowStaleInput: true) } }
                    }
                }
                if let row = model.recordedForecast { RecordedForecastView(row: row) }
                Text("forecast.disclaimer").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ValidationTable: View {
    let metrics: [ValidationMetrics]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Grid(alignment: .trailing, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                GridRow {
                    Text("forecast.model").gridColumnAlignment(.leading)
                    Text("forecast.metric.evaluations")
                    Text("forecast.metric.relativeMAE")
                    Text("forecast.metric.mase")
                    Text("forecast.metric.directional")
                    Text("forecast.metric.coverage80")
                    Text("forecast.metric.coverage95")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(metrics, id: \.model) { m in
                    GridRow {
                        Text(LocalizedStringKey("forecast.model.\(m.model.rawValue)")).gridColumnAlignment(.leading)
                        Text(verbatim: "\(m.evaluations)")
                        Text(Formatters.decimal(m.relativeMAE.flatMap { Decimal(finite: $0) }, fractionDigits: 2))
                        Text(Formatters.decimal(m.mase.flatMap { Decimal(finite: $0) }, fractionDigits: 2))
                        Text(Formatters.percent(m.directionalAccuracy, fractionDigits: 0))
                        Text(Formatters.percent(m.coverage80, fractionDigits: 0))
                        Text(Formatters.percent(m.coverage95, fractionDigits: 0))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            ForEach(metrics.filter { $0.model != .naive }, id: \.model) { m in
                Label(L10n.string(Message(m.isUsefulSignal ? "forecast.verdict.useful" : "forecast.verdict.notUseful",
                                          [.key("forecast.model.\(m.model.rawValue)")])),
                      systemImage: m.isUsefulSignal ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(m.isUsefulSignal ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecordedForecastView: View {
    let row: ForecastRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L10n.string(Message("forecast.recorded", [.date(row.targetDate)]))).font(.subheadline.weight(.semibold))
            Text(L10n.string(Message("forecast.interval80", [.decimal(Decimal(finite: row.lower80) ?? 0, fractionDigits: 2),
                                                              .decimal(Decimal(finite: row.upper80) ?? 0, fractionDigits: 2)])))
            Text(L10n.string(Message("forecast.interval95", [.decimal(Decimal(finite: row.lower95) ?? 0, fractionDigits: 2),
                                                              .decimal(Decimal(finite: row.upper95) ?? 0, fractionDigits: 2)])))
            Text(L10n.string(Message("forecast.median", [.decimal(Decimal(finite: row.point) ?? 0, fractionDigits: 2)])))
                .foregroundStyle(.secondary)
            if row.staleInput { Text("forecast.staleFlag").font(.caption).foregroundStyle(.orange) }
        }
        .font(.callout.monospacedDigit())
    }
}
