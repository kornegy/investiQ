import Charts
import SwiftUI
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices
import InvestiQPresentation

/// Investment simulator (spec §22): virtual money only, realistic costs, no rankings or rewards.
struct SimulatorView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SimulatorViewModel?
    @State private var lab: StrategyLabViewModel?
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("simulator.tabs", selection: $tab) {
                Text("simulator.tab.sessions").tag(0)
                Text("simulator.tab.strategy").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], Spacing.xl)
            if tab == 0 {
                if let model { SimulatorContent(model: model) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                if let lab { StrategyLabView(model: lab) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task {
            if model == nil { model = SimulatorViewModel(app: app) }
            if lab == nil { lab = StrategyLabViewModel(app: app) }
            await model?.load()
            await lab?.load()
        }
    }
}

private struct SimulatorContent: View {
    @Bindable var model: SimulatorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("section.simulator").font(.largeTitle.bold())
                Text("simulator.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { InlineMessage(message: error) }
                if !model.sessions.isEmpty {
                    Picker("simulator.session", selection: Binding(get: { model.selectedID },
                                                                   set: { id in if let id { Task { await model.select(id) } } })) {
                        ForEach(model.sessions, id: \.portfolio.id) { overview in
                            Text(overview.portfolio.name).tag(Optional(overview.portfolio.id))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                if let selected = model.selected {
                    SessionHeader(model: model, overview: selected)
                    if let report = model.report { ReportCard(model: model, report: report) }
                    OrderCard(model: model)
                    if let report = model.report, !report.insights.isEmpty { InsightsCard(insights: report.insights) }
                }
                NewSessionCard(model: model)
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
    }
}

private struct SessionHeader: View {
    let model: SimulatorViewModel
    let overview: SimulatorOverview

    var body: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(L10n.key("simulator.mode", overview.session.mode.rawValue)).font(.headline)
                    if overview.session.mode == .historical {
                        Text(L10n.string(Message("simulator.simDate", [.date(overview.session.simDate)]))).font(.title3)
                        Text("simulator.noFuture").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("simulator.liveNote").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if overview.session.mode == .historical {
                    HStack {
                        Button("simulator.advance.day") { Task { await model.advance(days: 1) } }
                        Button("simulator.advance.week") { Task { await model.advance(days: 7) } }
                        Button("simulator.advance.month") { Task { await model.advance(days: 30) } }
                    }
                    .disabled(!model.canAdvance)
                }
            }
        }
    }
}

private struct ReportCard: View {
    let model: SimulatorViewModel
    let report: SimulatorReport

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.m)], spacing: Spacing.m) {
                MetricTile(title: "simulator.metric.value", value: Formatters.money(report.valueBase, model.currency))
                MetricTile(title: "simulator.metric.cash", value: Formatters.money(report.cashBase, model.currency))
                MetricTile(title: "simulator.metric.costs", value: Formatters.money(report.costsBase, model.currency),
                           help: "simulator.metric.costs.help")
                MetricTile(title: "simulator.metric.benchmark", value: Formatters.money(report.benchmarkValueBase, model.currency),
                           help: "simulator.metric.benchmark.help", footnote: report.benchmarkName)
            }
            if let difference = model.differenceToBenchmark {
                Text(L10n.string(Message(difference >= 0 ? "simulator.benchmark.ahead" : "simulator.benchmark.behind",
                                         [.money(Money(abs(difference), model.currency))])))
                    .font(.callout)
            }
            if !report.snapshot.valuation.holdings.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        CardHeader(title: "simulator.holdings")
                        ForEach(report.snapshot.valuation.holdings, id: \.position.key) { holding in
                            HStack {
                                Text(report.snapshot.instruments[holding.position.key.instrumentID]?.name ?? "").lineLimit(1)
                                Spacer()
                                Text(Formatters.decimal(holding.position.quantity, fractionDigits: 2)).monospacedDigit()
                                Text(Formatters.money(holding.marketValueBase, model.currency)).monospacedDigit().frame(minWidth: 120, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct OrderCard: View {
    @Bindable var model: SimulatorViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "simulator.order.title", help: "simulator.order.help")
                HStack {
                    Picker("simulator.order.side", selection: $model.orderSide) {
                        Text("simulator.order.buy").tag(OrderSide.buy)
                        Text("simulator.order.sell").tag(OrderSide.sell)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    Picker("simulator.order.instrument", selection: $model.orderInstrumentID) {
                        Text("simulator.order.choose").tag(InstrumentID?.none)
                        ForEach(model.orderSide == .buy ? model.library : model.heldInstruments) { entry in
                            Text(entry.instrument.name).tag(Optional(entry.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    TextField("simulator.order.quantity", text: $model.orderQuantityText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }
                .onChange(of: model.orderInstrumentID) { Task { await model.updatePreview() } }
                .onChange(of: model.orderSide) { Task { await model.updatePreview() } }
                .onChange(of: model.orderQuantityText) { Task { await model.updatePreview() } }
                if let preview = model.preview {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                        row("simulator.order.reference", Formatters.decimal(preview.referencePrice, fractionDigits: 4) + " " + preview.tradeCurrency.rawValue)
                        row("simulator.order.fill", Formatters.decimal(preview.fillPrice, fractionDigits: 4) + " " + preview.tradeCurrency.rawValue)
                        row("simulator.order.value", Formatters.money(Money(preview.tradeValueBase, model.currency)))
                        row("simulator.order.commission", Formatters.money(Money(preview.commissionBase, model.currency)))
                        row("simulator.order.fxFee", Formatters.money(Money(preview.fxFeeBase, model.currency)))
                        row("simulator.order.spread", Formatters.money(Money(preview.spreadCostBase, model.currency)))
                        row(preview.side == .buy ? "simulator.order.totalBuy" : "simulator.order.totalSell",
                            Formatters.money(Money(preview.netCashBase, model.currency)))
                    }
                    .font(.callout.monospacedDigit())
                    if let price = model.previewPrice { SourceFooter(metadata: price.metadata) }
                }
                if let message = model.orderMessage {
                    InlineMessage(message: message, isError: message.key != "simulator.order.done")
                }
                Button(model.orderSide == .buy ? "simulator.order.placeBuy" : "simulator.order.placeSell") {
                    Task { await model.placeOrder() }
                }
                .disabled(model.preview == nil)
            }
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct InsightsCard: View {
    let insights: [SimulatorInsight]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: "simulator.insights.title", help: "simulator.insights.help")
                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                    Label(L10n.string(Self.message(insight)), systemImage: "lightbulb")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func message(_ insight: SimulatorInsight) -> Message {
        switch insight {
        case .highTurnover(let rate): return Message("simulator.insight.turnover", [.percent(rate, fractionDigits: 0)])
        case .highFees(let share): return Message("simulator.insight.fees", [.percent(share, fractionDigits: 1)])
        case .concentration(let name, let weight): return Message("simulator.insight.concentration", [.text(name), .percent(weight, fractionDigits: 0)])
        case .sellingAfterFall(let count): return Message("simulator.insight.sellingAfterFall", [.integer(count)])
        case .frequentTrading(let perMonth): return Message("simulator.insight.frequent", [.decimal(Decimal(finite: perMonth) ?? 0, fractionDigits: 1)])
        case .idleCash(let share): return Message("simulator.insight.idleCash", [.percent(share, fractionDigits: 0)])
        }
    }
}

private struct NewSessionCard: View {
    @Bindable var model: SimulatorViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "simulator.new.title", help: "simulator.new.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                    GridRow {
                        Text("simulator.new.name")
                        TextField("simulator.new.name", text: $model.newName).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("simulator.new.mode")
                        Picker("simulator.new.mode", selection: $model.newMode) {
                            ForEach(SimulatorMode.allCases, id: \.self) { Text(L10n.key("simulator.mode", $0.rawValue)).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if model.newMode == .historical {
                        GridRow {
                            Text("simulator.new.start")
                            DatePicker("simulator.new.start", selection: $model.newStartDate, displayedComponents: .date).labelsHidden()
                        }
                    }
                    GridRow {
                        Text("simulator.new.capital")
                        TextField("simulator.new.capital", text: $model.newCapitalText).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("simulator.new.benchmark")
                        Picker("simulator.new.benchmark", selection: $model.newBenchmarkID) {
                            Text("simulator.new.noBenchmark").tag(InstrumentID?.none)
                            ForEach(model.library) { Text($0.instrument.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: 560)
                Text("simulator.new.costs").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("simulator.new.create") {
                    Task {
                        _ = await model.createSession(defaultName: L10n.string("simulator.mode.\(model.newMode.rawValue)"))
                    }
                }
            }
        }
    }
}
