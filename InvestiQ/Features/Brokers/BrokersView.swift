import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Broker directory (spec §19): verified facts only, alphabetical, no ranking, no referral links.
struct BrokersView: View {
    @Environment(AppModel.self) private var app
    @State private var model: BrokersViewModel?

    var body: some View {
        Group {
            if let model { BrokersContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = BrokersViewModel(app: app) }
            model?.load()
        }
    }
}

private struct BrokersContent: View {
    @Bindable var model: BrokersViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("section.brokers").font(.largeTitle.bold())
                Text("brokers.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("brokers.protectionWarning", systemImage: "exclamationmark.shield")
                    .font(.callout)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.orange.opacity(0.1)))
                    .fixedSize(horizontal: false, vertical: true)
                if model.isEducationalMode {
                    Label("brokers.educationalMode", systemImage: "graduationcap").font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.error { InlineMessage(message: error) }
                Picker("brokers.filter", selection: $model.presenceFilter) {
                    Text("news.filter.all").tag(BrokerEntry.CzechPresence?.none)
                    ForEach(BrokerEntry.CzechPresence.allCases, id: \.self) {
                        Text(L10n.key("brokers.presence", $0.rawValue)).tag(Optional($0))
                    }
                }
                .frame(maxWidth: 360)
                ForEach(model.filtered) { broker in BrokerCard(model: model, broker: broker) }
                if let verified = model.verifiedOn {
                    Text(L10n.string(Message("brokers.verifiedOn", [.date(verified)]))).font(.caption).foregroundStyle(.secondary)
                }
                Text("brokers.disclaimer").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

private struct BrokerCard: View {
    let model: BrokersViewModel
    let broker: BrokerEntry

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(broker.brand).font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                    row("brokers.field.legalName", broker.legalName)
                    row("brokers.field.country", Locale.current.localizedString(forRegionCode: broker.country) ?? broker.country)
                    row("brokers.field.regulator", broker.regulator)
                    row("brokers.field.licence", L10n.string("brokers.licence.\(broker.licence.rawValue)"))
                    row("brokers.field.presence", L10n.string("brokers.presence.\(broker.czechPresence.rawValue)"))
                    row("brokers.field.protection", protectionText)
                    if let deposit = broker.depositProtectionCapEUR {
                        row("brokers.field.deposit", L10n.string(Message("brokers.deposit.value", [.integer(deposit)])))
                    }
                    row("brokers.field.fees", broker.fees ?? notVerified)
                    row("brokers.field.fxFees", broker.fxFees ?? notVerified)
                    row("brokers.field.minimum", broker.minimumDeposit ?? notVerified)
                    row("brokers.field.age", broker.minimumAge.map { "\($0)+" } ?? notVerified)
                    row("brokers.field.instruments", broker.instrumentTypes?.joined(separator: ", ") ?? notVerified)
                    row("brokers.field.identity", L10n.string("brokers.identity.general"))
                }
                .font(.callout)
                if let note = broker.investorProtection?.note {
                    Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(broker.openQuestionKeys ?? [], id: \.self) { key in
                    Label(LocalizedStringKey(key), systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.m) {
                    ExternalLinkButton(title: "brokers.register", url: broker.registerURL)
                    if let website = model.websiteURL(broker) { ExternalLinkButton(title: "brokers.website", url: website) }
                }
                DisclosureGroup("brokers.sources") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(broker.sources, id: \.self) { source in
                            Text(source.host ?? source.absoluteString).font(.caption).textSelection(.enabled)
                        }
                        Text(L10n.string(Message("brokers.verifiedOn", [.date(broker.verifiedOn)]))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var notVerified: String { L10n.string("brokers.notVerified") }

    private var protectionText: String {
        guard let protection = broker.investorProtection else { return notVerified }
        var parts = [protection.scheme]
        if let percent = protection.coveragePercent { parts.append(L10n.string(Message("brokers.protection.percent", [.integer(percent)]))) }
        if let cap = protection.capEUR { parts.append(L10n.string(Message("brokers.protection.cap", [.integer(cap)]))) }
        if protection.coveragePercent == nil || protection.capEUR == nil { parts.append(L10n.string("brokers.protection.detailsNotVerified")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
