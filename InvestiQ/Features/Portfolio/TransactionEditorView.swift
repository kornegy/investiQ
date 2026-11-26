import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Manual transaction entry. Fields adapt to the transaction type; numbers use the user's locale.
struct TransactionEditorView: View {
    let portfolio: Portfolio
    let editing: LedgerTransaction?
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var model: TransactionEditorViewModel?

    var body: some View {
        Group {
            if let model { EditorForm(model: model, done: done) } else { ProgressView() }
        }
        .frame(width: 520)
        .task {
            if model == nil { model = TransactionEditorViewModel(app: app, portfolio: portfolio, editing: editing, locale: L10n.locale) }
            await model?.load()
        }
    }
}

private struct EditorForm: View {
    @Bindable var model: TransactionEditorViewModel
    let done: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("transaction.field.type", selection: $model.type) {
                    ForEach(TransactionType.allCases, id: \.self) { Text(L10n.key("transaction.type", $0.rawValue)).tag($0) }
                }
                DatePicker("transaction.field.date", selection: $model.date, displayedComponents: .date)
                if model.usesInstrument {
                    Picker("transaction.field.instrumentID", selection: $model.instrumentID) {
                        Text("transaction.chooseInstrument").tag(InstrumentID?.none)
                        ForEach(model.instruments) { entry in Text(entry.instrument.name).tag(Optional(entry.id)) }
                    }
                }
                Picker("transaction.field.currency", selection: $model.currency) {
                    ForEach(currencies, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text(model.isVirtual ? "transaction.title.virtual" : "transaction.title.real").font(.title2.bold())
            }
            Section {
                if model.usesQuantityAndPrice {
                    TextField("transaction.field.quantity", text: $model.quantityText)
                    TextField("transaction.field.price", text: $model.priceText)
                }
                if model.usesAccruedInterest { TextField("transaction.field.accrued", text: $model.accruedInterestText) }
                if model.usesAmount { TextField("transaction.field.amount", text: $model.amountText) }
                if model.usesTax { TextField("transaction.field.tax", text: $model.taxText) }
                if model.usesSplit {
                    HStack {
                        TextField("transaction.field.splitNumerator", text: $model.splitNumeratorText)
                        Text(verbatim: ":")
                        TextField("transaction.field.splitDenominator", text: $model.splitDenominatorText)
                    }
                    Text("transaction.split.help").font(.caption).foregroundStyle(.secondary)
                }
                if model.usesCounter {
                    Picker("transaction.field.counterCurrency", selection: $model.counterCurrency) {
                        ForEach(currencies, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("transaction.field.counter", text: $model.counterAmountText)
                }
                if model.type != .split {
                    TextField("transaction.field.fees", text: $model.feesText)
                    if model.currency != model.baseCurrency {
                        Toggle(L10n.string(.init("transaction.feeInBase", [.text(model.baseCurrency.rawValue)])), isOn: $model.feeInBaseCurrency)
                        TextField(L10n.string(.init("transaction.field.fxRate", [.text(model.currency.rawValue), .text(model.baseCurrency.rawValue)])),
                                  text: $model.fxRateText)
                        Text("transaction.fx.help").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("transaction.field.notes", text: $model.notes, axis: .vertical).lineLimit(1...4)
            }
            if let error = model.error { InlineMessage(message: error) }
            HStack {
                Button("common.cancel", role: .cancel, action: done)
                Spacer()
                Button("common.save") { Task { await model.save(); if model.saved { done() } } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(Spacing.m)
    }

    private var currencies: [CurrencyCode] {
        Array(Set(CurrencyCode.supportedBaseCurrencies + [.gbp, .chf, .pln, model.currency])).sorted()
    }
}

/// Preview → confirm import of an InvestiQ CSV file (nothing is written before confirmation).
struct CSVImportView: View {
    let portfolioID: PortfolioID
    let data: Data
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var model: CSVImportViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("import.title").font(.title2.bold())
            if let model, let parsed = model.parsed {
                Text(L10n.string(.init("import.summary", [.integer(parsed.rows.count), .integer(parsed.errors.count)])))
                if !parsed.errors.isEmpty {
                    List(Array(parsed.errors.enumerated()), id: \.offset) { _, error in
                        Text(L10n.string(.init("import.rowError", [.integer(error.line), .text(L10n.string(error.message))])))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .frame(minHeight: 120)
                    Text("import.errorsSkipped").font(.caption).foregroundStyle(.secondary)
                }
                if let outcome = model.outcome {
                    InlineMessage(message: .init("import.done", [.integer(outcome.imported), .integer(outcome.skippedDuplicates),
                                                                 .integer(outcome.createdInstruments)]), isError: false)
                }
                if let error = model.error { InlineMessage(message: error) }
            } else {
                ProgressView()
            }
            Text("import.formatHelp").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model?.outcome == nil ? "common.cancel" : "common.ok", action: done)
                Spacer()
                Button("import.confirm") { Task { await model?.confirmImport() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(model?.canImport ?? false))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 460)
        .task {
            if model == nil {
                let created = CSVImportViewModel(app: app, portfolioID: portfolioID)
                created.preview(data)
                model = created
            }
        }
    }
}
