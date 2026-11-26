import Charts
import SwiftUI
import InvestiQCore
import InvestiQPresentation

struct CompareView: View {
    let ids: [InstrumentID]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: CompareViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("market.compare.title").font(.title2.bold())
                Spacer()
                Button("common.ok") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let model {
                Picker("asset.range", selection: Binding(get: { model.range }, set: { model.range = $0; Task { await model.load() } })) {
                    ForEach(ChartRange.allCases) { Text(L10n.key("range", $0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.columns.allSatisfy({ $0.rebased.isEmpty }) {
                    ContentUnavailableView("chart.noHistory", systemImage: "chart.xyaxis.line")
                } else {
                    Chart {
                        ForEach(model.columns) { column in
                            ForEach(column.rebased) { point in
                                LineMark(x: .value("date", point.date), y: .value("index", point.value))
                                    .foregroundStyle(by: .value("instrument", column.name))
                            }
                        }
                    }
                    .chartYAxisLabel { Text("market.compare.rebased") }
                    .frame(minHeight: 260)
                }
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                    GridRow {
                        Text("")
                        ForEach(model.columns) { Text($0.name).font(.headline).lineLimit(2) }
                    }
                    GridRow {
                        Text("asset.metric.periodReturn")
                        ForEach(model.columns) { Text(Formatters.percent($0.periodReturn)).font(.tableNumber) }
                    }
                    GridRow {
                        Text("asset.metric.volatility")
                        ForEach(model.columns) { Text(Formatters.percent($0.volatility)).font(.tableNumber) }
                    }
                    GridRow {
                        Text("asset.metric.maxDrawdown")
                        ForEach(model.columns) { Text(Formatters.percent($0.maxDrawdown.map { -$0 })).font(.tableNumber) }
                    }
                    GridRow {
                        Text("asset.currency")
                        ForEach(model.columns) { Text($0.currency.rawValue) }
                    }
                }
                Text("market.compare.currencyNote").font(.caption).foregroundStyle(.secondary)
                GeneralInformationNote()
            } else {
                ProgressView()
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 720, minHeight: 560)
        .task {
            if model == nil { model = CompareViewModel(app: app, instrumentIDs: ids) }
            await model?.load()
        }
    }
}
