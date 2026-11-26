import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// News and economic calendar (spec §16).
struct NewsView: View {
    @Environment(AppModel.self) private var app
    @State private var news: NewsViewModel?
    @State private var calendar: CalendarViewModel?
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("news.tabs", selection: $tab) {
                Text("news.tab.news").tag(0)
                Text("news.tab.calendar").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], Spacing.xl)
            if tab == 0 {
                if let news { NewsList(model: news) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                if let calendar { CalendarList(model: calendar) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task {
            if news == nil { news = NewsViewModel(app: app) }
            if calendar == nil { calendar = CalendarViewModel(app: app) }
            await news?.load()
            await calendar?.load()
        }
    }
}

private struct NewsList: View {
    @Bindable var model: NewsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Text("section.news").font(.largeTitle.bold())
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Button("news.refresh") { Task { await model.refresh() } }
                }
                Text("news.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.isOffline { InlineMessage(message: Message("news.offline")) }
                if let error = model.error { InlineMessage(message: error) }
                HStack {
                    TextField("news.search", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Picker("news.filter.category", selection: $model.categoryFilter) {
                        Text("news.filter.all").tag(NewsCategory?.none)
                        ForEach(NewsCategory.allCases, id: \.self) { Text(L10n.key("news.category", $0.rawValue)).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 260)
                    Picker("news.filter.type", selection: $model.typeFilter) {
                        Text("news.filter.all").tag(StatementType?.none)
                        ForEach(StatementType.allCases, id: \.self) { Text(L10n.key("news.type", $0.rawValue)).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 240)
                    Toggle("news.filter.mine", isOn: $model.onlyMyInstruments)
                }
                if model.filtered.isEmpty && !model.isLoading {
                    ContentUnavailableView("news.empty.title", systemImage: "newspaper", description: Text("news.empty.description"))
                }
                ForEach(model.filtered) { article in
                    NewsCard(model: model, article: article)
                }
                Text("news.copyrightNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
        }
    }
}

private struct NewsCard: View {
    let model: NewsViewModel
    let article: NewsArticle
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    TypeBadge(type: article.statementType)
                    Label(L10n.key("news.uncertainty", article.uncertainty.rawValue), systemImage: "questionmark.diamond")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if article.isDemo { Text("demo.label").font(.caption.weight(.semibold)).foregroundStyle(.purple) }
                    Spacer()
                    Text(Formatters.instant(article.publishedAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(article.headline).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let summary = article.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.xs) {
                    Text(article.sourceName).font(.caption.weight(.medium))
                    if !article.alsoReportedBy.isEmpty {
                        Text(L10n.string(Message("news.alsoReported", [.text(article.alsoReportedBy.joined(separator: ", "))])))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let eventDate = article.eventDate {
                        Text(L10n.string(Message("news.eventDate", [.date(eventDate)]))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !article.categories.isEmpty {
                    Text(article.categories.map { L10n.string("news.category.\($0.rawValue)") }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let related = model.relatedNames(article)
                if !related.isEmpty || !article.relatedSectors.isEmpty {
                    Text(L10n.string(Message("news.related", [.text((related + article.relatedSectors).joined(separator: ", "))])))
                        .font(.caption)
                }
                if let cue = article.statementCue {
                    Text(L10n.string(Message("news.classifiedBecause", [.text(cue)]))).font(.caption2).foregroundStyle(.secondary)
                }
                let effects = model.possibleEffects(article)
                if !effects.isEmpty {
                    DisclosureGroup("news.effects", isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(effects.enumerated()), id: \.offset) { _, effect in
                                Text(L10n.string(effect)).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: Spacing.m) {
                    if model.canOpen(article) {
                        ExternalLinkButton(title: "news.openOriginal", url: article.url)
                    }
                    AIExplainButton(title: "ai.summarize",
                                    task: .summarizeNews(headline: article.headline, summary: article.summary, source: article.sourceName))
                }
            }
        }
    }
}

private struct TypeBadge: View {
    @Environment(\.palette) private var palette
    let type: StatementType

    var body: some View {
        Text(L10n.key("news.type", type.rawValue))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch type {
        case .officialRelease: return palette.info
        case .reported: return .secondary
        case .opinion, .forecast: return .purple
        case .rumour: return palette.warning
        }
    }
}

private struct CalendarList: View {
    @Bindable var model: CalendarViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("calendar.title").font(.largeTitle.bold())
                Text("calendar.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let verified = model.verifiedOn {
                    Text(L10n.string(Message("calendar.verifiedOn", [.date(verified)]))).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { InlineMessage(message: error) }
                HStack {
                    Picker("calendar.filter.kind", selection: $model.kindFilter) {
                        Text("news.filter.all").tag(EconomicEventKind?.none)
                        ForEach(EconomicEventKind.allCases, id: \.self) { Text(L10n.key("calendar.kind", $0.rawValue)).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 280)
                    Picker("calendar.filter.region", selection: $model.regionFilter) {
                        Text("news.filter.all").tag(String?.none)
                        ForEach(model.regions, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 200)
                }
                ForEach(model.days, id: \.date) { day in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(Formatters.date(day.date)).font(.headline)
                        ForEach(day.events) { event in EventRow(model: model, event: event) }
                    }
                }
                Text("calendar.footnote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
        }
    }
}

private struct EventRow: View {
    let model: CalendarViewModel
    let event: EconomicEvent

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text(L10n.string(model.title(event))).font(.callout.weight(.semibold))
                    if event.status != .scheduled {
                        Text(L10n.key("calendar.status", event.status.rawValue)).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let reference = event.referencePeriod {
                    Text(L10n.string(Message("calendar.referencePeriod", [.text(reference)]))).font(.caption).foregroundStyle(.secondary)
                }
                if let previous = event.previousDate {
                    Text(L10n.string(Message("calendar.previousDate", [.date(previous)]))).font(.caption).foregroundStyle(.orange)
                }
                if let note = event.noteKey { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
                if let url = event.sourceURL { ExternalLinkButton(title: "calendar.source", url: url).font(.caption) }
            }
        }
    }

    /// Exact times are shown in the user's time zone with the source zone; date-only events say so.
    private var timeText: String {
        guard let instant = event.instant else { return L10n.string("calendar.timeNotPublished") }
        let local = instant.formatted(.dateTime.hour().minute().locale(L10n.locale))
        return L10n.string(Message("calendar.timeWithZone", [.text(local), .text(event.time ?? ""), .text(event.timeZone)]))
    }
}
