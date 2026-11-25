import SwiftUI
import InvestiQCore
import InvestiQData
import InvestiQServices
import InvestiQPresentation

/// Market Explorer (spec §9).
struct MarketView: View {
    @Environment(AppModel.self) private var app
    @State private var model: MarketExplorerViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { MarketContent(model: model) } else { ProgressView() }
            }
            .navigationDestination(for: InstrumentID.self) { AssetDetailView(instrumentID: $0) }
        }
        .task {
            if model == nil { model = MarketExplorerViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct MarketContent: View {
    @Bindable var model: MarketExplorerViewModel
    @Environment(AppModel.self) private var app
    @State private var showCompare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                if !model.hasMarketProviders && !app.isDemo {
                    Section {
                        Label("market.noProviders", systemImage: "network.slash").foregroundStyle(.secondary)
                        Button("market.openProviderSettings") { app.selectedSection = .settings }
                    }
                }
                if let error = model.error { InlineMessage(message: error) }
                Section("market.library") {
                    if model.filteredLibrary.isEmpty {
                        Text("market.libraryEmpty").foregroundStyle(.secondary)
                    }
                    ForEach(model.filteredLibrary) { entry in
                        InstrumentRow(entry: entry, quote: model.quotes[entry.id], isCompared: model.compareSelection.contains(entry.id),
                                      toggleWatchlist: { Task { await model.toggleWatchlist(entry.id) } },
                                      toggleCompare: { model.toggleCompare(entry.id) })
                    }
                }
                if model.isSearching || !model.remoteResults.isEmpty || !model.searchFailures.isEmpty {
                    Section("market.providerResults") {
                        if model.isSearching { ProgressView().controlSize(.small) }
                        ForEach(model.remoteResults) { result in
                            SearchResultRow(result: result) { Task { _ = await model.add(result) } }
                        }
                        ForEach(model.searchFailures, id: \.providerID) { failure in
                            Text(L10n.string(.init("market.providerFailed", [.text(failure.providerID),
                                                                              .key("provider.failure.\(ProviderFailureKey.key(failure.failure))")])))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle(Text("section.market"))
        .sheet(isPresented: $showCompare) { CompareView(ids: model.compareSelection) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                TextField("market.searchPlaceholder", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.runRemoteSearch() }
                    .accessibilityIdentifier("market.search")
                Button("market.searchProviders") { model.runRemoteSearch() }
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(Text("market.searchProviders.help"))
            }
            HStack(spacing: Spacing.m) {
                Picker("market.filter.kind", selection: $model.kindFilter) {
                    Text("market.filter.all").tag(InstrumentKind?.none)
                    ForEach(InstrumentKind.allCases, id: \.self) { Text(LocalizedStringKey("instrument.kind.\($0.rawValue)")).tag(Optional($0)) }
                }
                Picker("market.filter.country", selection: $model.countryFilter) {
                    Text("market.filter.all").tag(String?.none)
                    ForEach(model.availableCountries, id: \.self) { code in
                        Text(L10n.locale.localizedString(forRegionCode: code) ?? code).tag(Optional(code))
                    }
                }
                Picker("market.filter.sector", selection: $model.sectorFilter) {
                    Text("market.filter.all").tag(String?.none)
                    ForEach(model.availableSectors, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                Picker("market.filter.currency", selection: $model.currencyFilter) {
                    Text("market.filter.all").tag(CurrencyCode?.none)
                    ForEach(model.availableCurrencies, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Picker("market.sort", selection: $model.sortOrder) {
                    ForEach(MarketExplorerViewModel.SortOrder.allCases, id: \.self) { Text(LocalizedStringKey("market.sort.\($0.rawValue)")).tag($0) }
                }
                Toggle("market.watchlistOnly", isOn: $model.watchlistOnly)
                Spacer()
                Button {
                    showCompare = true
                } label: {
                    Label(L10n.string(.init("market.compareCount", [.integer(model.compareSelection.count)])), systemImage: "square.split.2x1")
                }
                .disabled(model.compareSelection.count < 2)
            }
            .controlSize(.small)
        }
        .padding(Spacing.m)
    }
}

private struct InstrumentRow: View {
    let entry: InstrumentEntry
    let quote: DataOutcome<Quote>?
    let isCompared: Bool
    let toggleWatchlist: () -> Void
    let toggleCompare: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button(action: toggleWatchlist) {
                Image(systemName: entry.inWatchlist ? "star.fill" : "star").foregroundStyle(entry.inWatchlist ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(entry.inWatchlist ? "market.removeFromWatchlist" : "market.addToWatchlist"))
            NavigationLink(value: entry.id) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.instrument.name).font(.body.weight(.medium))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let quote = quote?.value {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.money(Money(quote.value.price, quote.value.currency))).font(.tableNumber)
                            if let change = quote.value.changePercent {
                                ChangeLabel(direction: ChangeDirection(change), text: Formatters.percent((change / 100).doubleValue))
                            }
                            FreshnessBadge(delay: quote.metadata.delay)
                        }
                    } else {
                        Text("value.missing").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("", isOn: Binding(get: { isCompared }, set: { _ in toggleCompare() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(Text("market.compare.help"))
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [L10n.string("instrument.kind.\(entry.instrument.kind.rawValue)")]
        if let listing = entry.listing { parts.append([listing.ticker.rawValue, listing.mic?.rawValue].compactMap { $0 }.joined(separator: " · ")) }
        if let isin = entry.instrument.isin { parts.append(isin.rawValue) }
        return parts.joined(separator: " · ")
    }
}

private struct SearchResultRow: View {
    let result: InstrumentSearchResult
    let add: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                Text([result.symbol, result.exchangeName, result.currency?.rawValue, result.isin?.rawValue].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.string(.init("market.foundVia", [.text(result.providerID)]))).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("market.add", action: add).disabled(result.currency == nil)
        }
    }
}
