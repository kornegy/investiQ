import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Public forecast accuracy record (spec §14): every stored forecast with its outcome — failures included.
struct ForecastAccuracyView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ForecastAccuracyViewModel?

    var body: some View {
        Group {
            if let model { ForecastAccuracyContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = ForecastAccuracyViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct ForecastAccuracyContent: View {
    let model: ForecastAccuracyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("forecast.record.intro").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { InlineMessage(message: error) }
            if model.items.isEmpty {
                ContentUnavailableView("forecast.record.empty.title", systemImage: "list.bullet.clipboard",
                                       description: Text("forecast.record.empty.description"))
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        CardHeader(title: "forecast.record.accuracy", help: "forecast.record.accuracy.help")
                        Grid(alignment: .trailing, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                            GridRow {
                                Text("forecast.model").gridColumnAlignment(.leading)
                                Text("forecast.record.evaluated")
                                Text("forecast.record.pending")
                                Text("forecast.record.mape")
                                Text("forecast.record.naiveMape")
                                Text("forecast.metric.coverage80")
                                Text("forecast.metric.directional")
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(model.accuracy, id: \.modelID) { row in
                                GridRow {
                                    Text(L10n.key("forecast.model", row.modelID)).gridColumnAlignment(.leading)
                                    Text(verbatim: "\(row.evaluated)")
                                    Text(verbatim: "\(row.pending)")
                                    Text(Formatters.percent(row.meanAbsolutePercentError, fractionDigits: 1))
                                    Text(Formatters.percent(row.naiveMeanAbsolutePercentError, fractionDigits: 1))
                                    Text(Formatters.percent(row.coverage80, fractionDigits: 0))
                                    Text(Formatters.percent(row.directionalAccuracy, fractionDigits: 0))
                                }
                                .font(.caption.monospacedDigit())
                            }
                        }
                        Text("forecast.record.smallSample").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(model.items) { item in
                    ForecastRecordRow(item: item)
                }
            }
        }
    }
}

private struct ForecastRecordRow: View {
    let item: ForecastRecordItem

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text(item.instrumentName).font(.headline).lineLimit(1)
                    Spacer()
                    Text(L10n.key("forecast.model", item.row.modelID)).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.string(Message("forecast.record.period", [.date(item.row.originDate), .date(item.row.targetDate)])))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.string(Message("forecast.interval80", [.decimal(Decimal(finite: item.row.lower80) ?? 0, fractionDigits: 2),
                                                                  .decimal(Decimal(finite: item.row.upper80) ?? 0, fractionDigits: 2)])))
                    .font(.callout.monospacedDigit())
                if let evaluation = item.row.evaluation {
                    Label(L10n.string(Message(evaluation.within80 ? "forecast.record.inside" : "forecast.record.outside",
                                              [.decimal(Decimal(finite: evaluation.actual) ?? 0, fractionDigits: 2)])),
                          systemImage: evaluation.within80 ? "checkmark.circle" : "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(evaluation.within80 ? Color.secondary : Color.orange)
                } else {
                    Label("forecast.record.awaiting", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
                }
                if item.row.staleInput { Text("forecast.staleFlag").font(.caption).foregroundStyle(.orange) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
