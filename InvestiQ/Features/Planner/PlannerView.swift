import Charts
import SwiftUI
import InvestiQCore
import InvestiQAnalytics
import InvestiQPresentation

/// Financial planner (spec §17). Educational: it explains consequences and never proposes how much to invest.
struct PlannerView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PlannerViewModel?

    var body: some View {
        Group {
            if let model { PlannerContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = PlannerViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct PlannerContent: View {
    @Bindable var model: PlannerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("section.planner").font(.largeTitle.bold())
                Text("planner.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { InlineMessage(message: error) }
                BudgetCard(model: model)
                if let analysis = model.analysis { AnalysisCard(analysis: analysis, currency: model.currency) }
                ShockCard(model: model)
                SavingsCard(model: model)
                PortfolioChangeCard(model: model)
                GoalsCard(model: model)
                GeneralInformationNote()
            }
            .padding(Spacing.xl)
        }
    }
}

private struct BudgetCard: View {
    @Bindable var model: PlannerViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "planner.budget.title", help: "planner.budget.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                    ForEach(PlannerViewModel.Field.allCases) { field in
                        GridRow {
                            Text(LocalizedStringKey(field.labelKey))
                            TextField(LocalizedStringKey("planner.field.placeholder"), text: Binding(
                                get: { model.texts[field] ?? "" },
                                set: { model.texts[field] = $0; model.recompute() }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                                .accessibilityLabel(Text(LocalizedStringKey(field.labelKey)))
                            Text(model.currency.rawValue).foregroundStyle(.secondary)
                            if model.invalidField == field {
                                Text("planner.field.invalid").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                HStack {
                    Button("common.save") { Task { await model.save() } }
                        .disabled(model.invalidField != nil)
                    if model.saved { Text("planner.saved").font(.caption).foregroundStyle(.secondary) }
                }
                Text("planner.privacy").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AnalysisCard: View {
    let analysis: BudgetAnalysis
    let currency: CurrencyCode

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.m)], spacing: Spacing.m) {
                MetricTile(title: "planner.metric.freeCashFlow", value: Formatters.money(analysis.freeCashFlow, currency),
                           help: "planner.metric.freeCashFlow.help")
                MetricTile(title: "planner.metric.ratio", value: Formatters.decimal(analysis.incomeToExpenseRatio),
                           help: "planner.metric.ratio.help")
                MetricTile(title: "planner.metric.coverage",
                           value: analysis.emergencyCoverageMonths.map {
                               L10n.string(Message("planner.months", [.decimal($0, fractionDigits: 1)]))
                           } ?? L10n.string("value.missing"),
                           help: "planner.metric.coverage.help")
            }
            ForEach(analysis.notes, id: \.self) { note in
                Label(LocalizedStringKey(note.messageKey), systemImage: "lightbulb")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.blue.opacity(0.08)))
            }
        }
    }
}

private struct ShockCard: View {
    @Bindable var model: PlannerViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "planner.shock.title", help: "planner.shock.help")
                HStack {
                    Text("planner.shock.incomeLoss")
                    TextField("planner.shock.incomeLoss", value: $model.incomeLossPercent, format: .number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                    Text(verbatim: "%")
                }
                if let loss = model.incomeLoss {
                    Text(L10n.string(Message("planner.shock.balance", [.money(Money(loss.monthlyBalance, model.currency))])))
                    if let months = loss.monthsUntilReservesExhausted {
                        Text(L10n.string(Message("planner.shock.reservesLast", [.decimal(months, fractionDigits: 1)])))
                            .foregroundStyle(.orange)
                    } else {
                        Text("planner.shock.covered").foregroundStyle(.secondary)
                    }
                } else {
                    Text("planner.shock.needBudget").foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("planner.shock.expense")
                    TextField("planner.shock.expense", value: $model.unexpectedExpense, format: .number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                    Text(model.currency.rawValue).foregroundStyle(.secondary)
                }
                if let result = model.unexpectedExpenseResult {
                    Text(L10n.string(Message("planner.shock.remaining", [.money(Money(result.remainingReserves, model.currency))])))
                    if result.shortfall > 0 {
                        Text(L10n.string(Message("planner.shock.shortfall", [.money(Money(result.shortfall, model.currency))])))
                            .foregroundStyle(.orange)
                    }
                    if let months = result.monthsToRebuild {
                        Text(L10n.string(Message("planner.shock.rebuild", [.decimal(months, fractionDigits: 1)]))).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }
}

private struct SavingsCard: View {
    @Bindable var model: PlannerViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "planner.savings.title", help: "planner.savings.help")
                Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                    GridRow {
                        Text("planner.savings.initial")
                        TextField("planner.savings.initial", value: $model.savingsInitial, format: .number).textFieldStyle(.roundedBorder)
                        Text("planner.savings.monthly")
                        TextField("planner.savings.monthly", value: $model.savingsMonthly, format: .number).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("planner.savings.return")
                        TextField("planner.savings.return", value: $model.savingsReturnPercent, format: .number).textFieldStyle(.roundedBorder)
                        Text("planner.savings.inflation")
                        TextField("planner.savings.inflation", value: $model.inflationPercent, format: .number).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("planner.savings.years")
                        Stepper(value: $model.savingsYears, in: 1...40) { Text(verbatim: "\(model.savingsYears)") }
                    }
                }
                .frame(maxWidth: 640)
                let points = model.savings
                let baseline = model.savingsWithoutReturn
                if !points.isEmpty {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("year", point.year), y: .value("value", point.nominalValue.doubleValue))
                                .foregroundStyle(by: .value("series", L10n.string("planner.savings.nominal")))
                            LineMark(x: .value("year", point.year), y: .value("value", point.realValue.doubleValue))
                                .foregroundStyle(by: .value("series", L10n.string("planner.savings.real")))
                        }
                        ForEach(baseline) { point in
                            LineMark(x: .value("year", point.year), y: .value("value", point.contributed.doubleValue))
                                .foregroundStyle(by: .value("series", L10n.string("planner.savings.contributed")))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .frame(height: 220)
                    .accessibilityLabel(Text("planner.savings.title"))
                    if let last = points.last {
                        Text(L10n.string(Message("planner.savings.summary", [
                            .integer(last.year), .money(Money(last.contributed, model.currency)),
                            .money(Money(last.nominalValue, model.currency)), .money(Money(last.realValue, model.currency))])))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("planner.savings.note").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PortfolioChangeCard: View {
    @Bindable var model: PlannerViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "planner.portfolio.title", help: "planner.portfolio.help")
                HStack {
                    Text("planner.portfolio.value")
                    TextField("planner.portfolio.value", value: $model.portfolioValue, format: .number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    Text(model.currency.rawValue).foregroundStyle(.secondary)
                }
                ForEach(model.portfolioChanges) { scenario in
                    HStack {
                        Text(Formatters.percent(scenario.change.doubleValue, fractionDigits: 0)).frame(width: 60, alignment: .trailing)
                        Text(Formatters.money(Money(scenario.newValue, model.currency))).monospacedDigit()
                        Spacer()
                        if let months = scenario.monthsOfExpenses {
                            Text(L10n.string(Message("planner.portfolio.months", [.decimal(months, fractionDigits: 1)])))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                Text("planner.portfolio.note").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GoalsCard: View {
    let model: PlannerViewModel
    @State private var name = ""
    @State private var amount = ""
    @State private var term: PlannerGoal.Term = .short
    @State private var hasDate = true
    @State private var date = Date().addingTimeInterval(365 * 86_400)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "planner.goals.title", help: "planner.goals.help")
                ForEach(model.goals) { goal in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(goal.name).font(.headline)
                            Text(LocalizedStringKey("planner.goal.term.\(goal.term.rawValue)")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(Formatters.money(Money(goal.targetAmount, goal.currency))).monospacedDigit()
                            if let date = goal.targetDate { Text(Formatters.date(date)).font(.caption).foregroundStyle(.secondary) }
                            if let monthly = model.monthlyAmount(for: goal) {
                                Text(L10n.string(Message("planner.goal.monthly", [.money(Money(monthly, goal.currency))])))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) { Task { await model.deleteGoal(goal) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("common.delete"))
                    }
                }
                Divider()
                HStack {
                    TextField("planner.goal.name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("planner.goal.amount", text: $amount).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                    Picker("planner.goal.term", selection: $term) {
                        ForEach(PlannerGoal.Term.allCases, id: \.self) { Text(LocalizedStringKey("planner.goal.term.\($0.rawValue)")).tag($0) }
                    }
                    .frame(maxWidth: 200)
                }
                HStack {
                    Toggle("planner.goal.hasDate", isOn: $hasDate)
                    if hasDate { DatePicker("planner.goal.date", selection: $date, displayedComponents: .date).labelsHidden() }
                    Spacer()
                    Button("planner.goal.add") {
                        Task {
                            let target = hasDate ? LocalDate(date, timeZone: .current) : nil
                            if await model.addGoal(name: name, term: term, amountText: amount, targetDate: target) {
                                name = ""
                                amount = ""
                            }
                        }
                    }
                }
            }
        }
    }
}
