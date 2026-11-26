import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// News (spec §16): classified, deduplicated items with sources, uncertainty and cautious cause-and-effect
/// explanations. Nothing here says a market will rise or fall because of a news item.
@MainActor
@Observable
public final class NewsViewModel {
    public private(set) var articles: [NewsArticle] = []
    public private(set) var instrumentNames: [InstrumentID: String] = [:]
    public private(set) var isLoading = false
    public private(set) var isOffline = false
    public private(set) var error: Message?
    public var categoryFilter: NewsCategory?
    public var typeFilter: StatementType?
    public var onlyMyInstruments = false
    public var query = ""

    private let app: AppModel
    private var myInstrumentIDs: Set<InstrumentID> = []

    public init(app: AppModel) { self.app = app }

    public func load() async {
        guard let services = app.services else { return }
        do {
            try await loadContext(services)
            articles = NewsDeduplicator.merge(try await services.news.cached())
        } catch {
            self.error = Message("news.error.loadFailed")
        }
        await refresh()
    }

    private func loadContext(_ services: SessionServices) async throws {
        let library = try await services.instruments.library()
        instrumentNames = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.instrument.name) })
        var mine = Set(library.filter(\.inWatchlist).map(\.id))
        for portfolio in try await services.portfolios.portfolios() {
            mine.formUnion(try await services.portfolios.transactions(portfolio.id).compactMap(\.instrumentID))
        }
        myInstrumentIDs = mine
    }

    public func refresh() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let outcome = try await services.news.refresh()
            articles = outcome.articles
            isOffline = outcome.isOffline
            error = nil
        } catch {
            isOffline = true
            self.error = Message("news.error.refreshFailed")
        }
    }

    public var filtered: [NewsArticle] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return articles.filter { article in
            (categoryFilter.map { article.categories.contains($0) } ?? true)
                && (typeFilter.map { article.statementType == $0 } ?? true)
                && (!onlyMyInstruments || !myInstrumentIDs.isDisjoint(with: article.relatedInstrumentIDs))
                && (text.isEmpty || article.headline.lowercased().contains(text) || (article.summary ?? "").lowercased().contains(text))
        }
    }

    /// Demo links point to the reserved `.invalid` domain and are never opened.
    public func canOpen(_ article: NewsArticle) -> Bool { !article.isDemo && article.url.scheme == "https" }

    /// Possible channels of effect for the item's first categories, always with the caveat that the actual
    /// reaction depends on expectations and other circumstances (spec §16).
    public func possibleEffects(_ article: NewsArticle) -> [Message] {
        let effects = article.categories.prefix(2).map { Message("news.effect.\($0.rawValue)") }
        return effects.isEmpty ? [] : effects + [Message("news.effect.caveat")]
    }

    public func relatedNames(_ article: NewsArticle) -> [String] {
        article.relatedInstrumentIDs.compactMap { instrumentNames[$0] }.sorted()
    }
}
