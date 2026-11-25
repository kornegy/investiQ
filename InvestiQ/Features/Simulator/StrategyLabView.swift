import Charts
import SwiftUI
import InvestiQCore
import InvestiQAnalytics
import InvestiQPresentation

/// Strategy lab: how a fixed allocation would have behaved in the past, with costs. Not a prediction.
struct StrategyLabView: View {
    @Bindable var model: StrategyLabViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("strategy.title").font(.largeTitle.bold())
                Text("strategy.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Card {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        CardHeader(title: "strategy.allocation", help: "strategy.allocation.help")
                        ForEach($model.rows) { $row in
                            HStack {
                                Picker("strategy.instrument", selection: $row.instrumentID) {
                                    Text("simulator.order.choose").tag(InstrumentID?.none)
                                    ForEach(model.library) { Text($0.instrument.name).tag(Optional($0.id)) }
                                }
                                .frame(maxWidth: 380)
                                TextField("strategy.weight", text: $row.weightText).textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                                Text(verbatim: "%")
                                Button { model.removeRow(row) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(Text("common.delete"))
                                    .disabled(model.rows.count <= 1)
                            }
                        }
                        HStack {
                            Button("strategy.addRow") { model.addRow() }
                            Spacer()
                            Text(L10n.string(Message("strategy.weightSum", [.decimal(model.weightSum, fractionDigits: 0)])))
                                .foregroundStyle(model.weightSum == 100 ? Color.secondary : Color.orange)
                        }
                        Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                            GridRow {
                                Text("strategy.initial")
                                TextField("strategy.initial", text: $model.initialText).textFieldStyle(.roundedBorder)
                                Text("strategy.monthly")
                                TextField("strategy.monthly", text: $model.monthlyText).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("strategy.start")
                                DatePicker("strategy.start", selection: $model.start, displayedComponents: .date).labelsHidden()
                                Text("strategy.end")
                                DatePicker("strategy.end", selection: $model.end, displayedComponents: .date).labelsHidden()
                            }
                            GridRow {
                                Text("strategy.rebalancing")
                                Picker("strategy.rebalancing", selection: $model.rebalancing) {
                                    ForEach(StrategyBacktest.Rebalancing.allCases, id: \.self) {
                                        Text(LocalizedStringKey("strategy.rebalancing.\($0.rawValue)")).tag($0)
                                    }
                                }
                                .labelsHidden()
                                Text("strategy.benchmark")
                                Picker("strategy.benchmark", selection: $model.benchmarkID) {
                                    Text("simulator.new.noBenchmark").tag(InstrumentID?.none)
                                    ForEach(model.library) { Text($0.instrument.name).tag(Optional($0.id)) }
                                }
                                .labelsHidden()
                            }
                        }
                        HStack {
                            Button("strategy.run") { Task { await model.run() } }.disabled(model.isRunning)
                            if model.isRunning { ProgressView().controlSize(.small) }
                        }
                        if let error = model.error { InlineMessage(message: error) }
                    }
                }
                if let result = model.strategy { ResultCard(model: model, strategy: result, benchmark: model.benchmark) }
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
    }
}

private struct ResultCard: View {
    let model: StrategyLabViewModel
    let strategy: StrategyBacktest.Result
    let benchmark: StrategyBacktest.Result?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "strategy.result", help: "strategy.result.help")
                Chart {
                    ForEach(sample(strategy.points)) { point in
                        LineMark(x: .value("date", point.date.startOfDay(in: .current)), y: .value("value", point.value))
                            .foregroundStyle(by: .value("series", L10n.string("strategy.series.strategy")))
                    }
                    if let benchmark {
                        ForEach(sample(benchmark.points)) { point in
                            LineMark(x: .value("date", point.date.startOfDay(in: .current)), y: .value("value", point.value))
                                .foregroundStyle(by: .value("series", L10n.string("strategy.series.benchmark")))
                        }
                    }
                    ForEach(sample(strategy.points)) { point in
                        LineMark(x: .value("date", point.date.startOfDay(in: .current)), y: .value("value", point.contributed))
                            .foregroundStyle(by: .value("series", L10n.string("strategy.series.contributed")))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .frame(height: 260)
                .accessibilityLabel(Text("strategy.result"))
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                    GridRow {
                        Text(verbatim: "")
                        Text("strategy.series.strategy").font(.caption.weight(.semibold))
                        Text("strategy.series.benchmark").font(.caption.weight(.semibold))
                    }
                    metricRow("strategy.metric.final", money(strategy.finalValue), benchmark.map { money($0.finalValue) })
                    metricRow("strategy.metric.contributed", money(strategy.contributed), benchmark.map { money($0.contributed) })
                    metricRow("strategy.metric.twr", Formatters.percent(strategy.timeWeightedReturn, fractionDigits: 1),
                              benchmark.map { Formatters.percent($0.timeWeightedReturn, fractionDigits: 1) })
                    metricRow("strategy.metric.volatility", Formatters.percent(strategy.annualVolatility, fractionDigits: 1),
                              benchmark.map { Formatters.percent($0.annualVolatility, fractionDigits: 1) })
                    metricRow("strategy.metric.drawdown", Formatters.percent(strategy.maxDrawdown, fractionDigits: 1),
                              benchmark.map { Formatters.percent($0.maxDrawdown, fractionDigits: 1) })
                    metricRow("strategy.metric.costs", money(strategy.costs), benchmark.map { money($0.costs) })
                    metricRow("strategy.metric.rebalances", "\(strategy.rebalances)", nil)
                }
                .font(.callout.monospacedDigit())
                Text("strategy.disclaimer").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func money(_ value: Double) -> String { Formatters.money(Decimal(finite: value), model.baseCurrency) }

    private func metricRow(_ key: LocalizedStringKey, _ strategy: String, _ benchmark: String?) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(strategy)
            Text(benchmark ?? "—")
        }
    }

    /// At most ~400 points per line for chart performance.
    private func sample(_ points: [StrategyBacktest.Point]) -> [StrategyBacktest.Point] {
        let step = max(1, points.count / 400)
        return points.enumerated().filter { $0.offset % step == 0 || $0.offset == points.count - 1 }.map(\.element)
    }
}
