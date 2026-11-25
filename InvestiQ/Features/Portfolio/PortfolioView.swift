import SwiftUI
import UniformTypeIdentifiers
import InvestiQCore
import InvestiQServices
import InvestiQPresentation

/// Portfolio section (spec §21): holdings, transactions, manual entry, CSV import/export.
struct PortfolioView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PortfolioViewModel?

    var body: some View {
        Group {
            if let model { PortfolioContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = PortfolioViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct PortfolioContent: View {
    @Bindable var model: PortfolioViewModel
    @Environment(AppModel.self) private var app
    @State private var showNewPortfolio = false
    @State private var newPortfolioName = ""
    @State private var editorTransaction: EditorRequest?
    @State private var showImporter = false
    @State private var importData: Data?
    @State private var exportDocument: CSVDocument?
    @State private var confirmDeletePortfolio = false
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(Spacing.m)
            Divider()
            if let error = model.error { InlineMessage(message: error).padding(Spacing.m) }
            if model.portfolios.isEmpty {
                ContentUnavailableView {
                    Label("portfolio.empty.title", systemImage: "briefcase")
                } description: {
                    Text(model.kind == .virtual ? "portfolio.empty.virtual" : "portfolio.empty.real")
                } actions: {
                    Button("portfolio.new") { showNewPortfolio = true }
                }
            } else {
                Picker("", selection: $tab) {
                    Text("portfolio.tab.holdings").tag(0)
                    Text("portfolio.tab.transactions").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(Spacing.m)
                if tab == 0 { HoldingsList(model: model) } else { TransactionsList(model: model, edit: { editorTransaction = EditorRequest(transaction: $0) }) }
            }
        }
        .sheet(isPresented: $showNewPortfolio) { newPortfolioSheet }
        .sheet(item: $editorTransaction) { request in
            if let portfolio = model.portfolios.first(where: { $0.id == model.selectedPortfolioID }) {
                TransactionEditorView(portfolio: portfolio, editing: request.transaction) {
                    editorTransaction = nil
                    Task { try? await model.reloadSelected() }
                }
            }
        }
        .sheet(item: Binding(get: { importData.map { ImportRequest(data: $0) } }, set: { if $0 == nil { importData = nil } })) { request in
            if let id = model.selectedPortfolioID {
                CSVImportView(portfolioID: id, data: request.data) {
                    importData = nil
                    Task { try? await model.reloadSelected() }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            importData = try? Data(contentsOf: url)
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "investiq-transactions") { _ in
            exportDocument = nil
        }
        .confirmationDialog(Text("portfolio.delete.confirm"), isPresented: $confirmDeletePortfolio) {
            Button("portfolio.delete", role: .destructive) { Task { await model.deleteSelectedPortfolio() } }
            Button("common.cancel", role: .cancel) {}
        }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.m) {
            if model.realPortfoliosAllowed {
                Picker("", selection: Binding(get: { model.kind }, set: { kind in model.kind = kind; model.selectedPortfolioID = nil; Task { await model.load() } })) {
                    Text("portfolio.kind.real").tag(PortfolioKind.real)
                    Text("portfolio.kind.virtual").tag(PortfolioKind.virtual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Picker("portfolio.select", selection: Binding(get: { model.selectedPortfolioID }, set: { id in Task { await model.select(id) } })) {
                ForEach(model.portfolios) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 260)
            Spacer()
            Button { showNewPortfolio = true } label: { Label("portfolio.new", systemImage: "plus") }
            Button { editorTransaction = EditorRequest(transaction: nil) } label: { Label("portfolio.addTransaction", systemImage: "plus.circle") }
                .disabled(model.selectedPortfolioID == nil)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu {
                Button("portfolio.import") { showImporter = true }.disabled(model.selectedPortfolioID == nil)
                Button("portfolio.export") {
                    Task { if let csv = await model.exportCSV() { exportDocument = CSVDocument(text: csv) } }
                }
                .disabled(model.selectedPortfolioID == nil)
                Divider()
                Button("portfolio.delete", role: .destructive) { confirmDeletePortfolio = true }.disabled(model.selectedPortfolioID == nil)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
    }

    private var newPortfolioSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(model.kind == .virtual || !model.realPortfoliosAllowed ? "portfolio.new.virtual" : "portfolio.new.real").font(.title2.bold())
            TextField("portfolio.name", text: $newPortfolioName).textFieldStyle(.roundedBorder)
            HStack {
                Button("common.cancel", role: .cancel) { showNewPortfolio = false }
                Spacer()
                Button("portfolio.create") {
                    let name = newPortfolioName
                    newPortfolioName = ""
                    showNewPortfolio = false
                    Task { await model.createPortfolio(name: name, baseCurrency: app.preferences.baseCurrency) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPortfolioName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    let transaction: LedgerTransaction?
}

struct ImportRequest: Identifiable {
    let id = UUID()
    let data: Data
}

private struct HoldingsList: View {
    let model: PortfolioViewModel

    var body: some View {
        if let snapshot = model.snapshot {
            let currency = snapshot.portfolio.baseCurrency
            List {
                ForEach(snapshot.valuation.holdings) { holding in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.instruments[holding.position.key.instrumentID]?.name ?? "?").font(.body.weight(.medium))
                            Text(L10n.string(.init("portfolio.holding.detail", [.decimal(holding.position.quantity, fractionDigits: 4),
                                                                                 .text(Formatters.money(holding.position.averageCost, holding.position.key.currency))])))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.money(holding.marketValueBase, currency)).font(.tableNumber)
                            if let unrealized = holding.unrealizedBase {
                                ChangeLabel(direction: ChangeDirection(unrealized), text: Formatters.money(unrealized, currency))
                            }
                            if let weight = holding.weight { Text(Formatters.percent(weight, fractionDigits: 1)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .help(Text(L10n.string(.init("portfolio.holding.effects", [.text(Formatters.money(holding.priceEffectBase, currency)),
                                                                                .text(Formatters.money(holding.fxEffectBase, currency))]))))
                }
                if snapshot.valuation.holdings.isEmpty { Text("portfolio.noHoldings").foregroundStyle(.secondary) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TransactionsList: View {
    let model: PortfolioViewModel
    let edit: (LedgerTransaction) -> Void
    @State private var pendingDeletion: LedgerTransaction?

    var body: some View {
        List {
            ForEach(model.transactions) { transaction in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey("transaction.type.\(transaction.type.rawValue)")).font(.body.weight(.medium))
                        Text([Formatters.date(transaction.tradeDate), model.instrumentName(transaction.instrumentID)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(summary(transaction)).font(.tableNumber)
                    Menu {
                        Button("transaction.edit") { edit(transaction) }
                        Button("transaction.delete", role: .destructive) { pendingDeletion = transaction }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
            }
            if model.transactions.isEmpty { Text("portfolio.noTransactions").foregroundStyle(.secondary) }
        }
        .confirmationDialog(Text("transaction.delete.confirm"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("transaction.delete", role: .destructive) {
                if let transaction = pendingDeletion { Task { await model.delete(transaction) } }
                pendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        }
    }

    private func summary(_ t: LedgerTransaction) -> String {
        if let quantity = t.quantity, let price = t.price {
            return "\(Formatters.decimal(quantity, fractionDigits: 4)) × \(Formatters.money(price, t.currency))"
        }
        if let amount = t.amount { return Formatters.money(amount, t.currency) }
        if let n = t.splitNumerator, let d = t.splitDenominator { return "\(n):\(d)" }
        return ""
    }
}

/// Plain CSV document for `fileExporter`.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
