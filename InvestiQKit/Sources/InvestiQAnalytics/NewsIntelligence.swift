import Foundation
import InvestiQCore

/// Rule-based, explainable news classification (FINANCIAL_METHODOLOGY §12, M-NEWS). Keyword lists cover
/// English and Czech because that is what the configured sources publish. No AI, no sentiment score,
/// and never a claim that news will move a price in a given direction.
public enum NewsClassifier {
    static let categoryKeywords: [NewsCategory: [String]] = [
        .centralBanks: ["central bank", "ecb", "federal reserve", "fomc", "the fed", "governing council", "monetary policy",
                        "čnb", "česká národní banka", "bankovní rada", "měnová politika", "lagarde", "powell"],
        .interestRates: ["interest rate", "rate cut", "rate hike", "policy rate", "deposit facility", "yield", "basis points",
                         "úrokov", "sazb", "repo sazba"],
        .inflation: ["inflation", "consumer prices", "cpi", "hicp", "price index", "inflac", "spotřebitelské ceny", "deflation"],
        .employment: ["employment", "unemployment", "payrolls", "jobs report", "labour market", "labor market", "wages",
                      "nezaměstnanost", "zaměstnanost", "mzdy"],
        .corporateEarnings: ["earnings", "quarterly results", "revenue", "profit", "guidance", "dividend", "výsledky hospodaření", "zisk", "tržby"],
        .geopolitics: ["sanction", "war ", "wars ", "election", "tariff", "trade dispute", "conflict", "geopolit", "sankce", "válk", "volby", "cla "],
        .energy: ["oil ", "gas ", "energy", "electricity", "opec", "brent", "ropa", "plyn", "energi", "elektřin"],
        .technology: ["technology", "semiconductor", "chip", "artificial intelligence", "software", "cloud", "technolog", "polovodič"],
        .regulation: ["regulation", "regulator", "directive", "supervision", "esma", "mifid", "license", "licence", "fine ",
                      "regulac", "dohled", "pokut", "směrnic"],
        .europeanMarkets: ["euro area", "eurozone", "europe", "stoxx", "dax", "eurozóna", "evropsk"],
        .usMarkets: ["wall street", "s&p 500", "nasdaq", "dow jones", "u.s.", "united states", "us economy", "usa "],
        .czechEconomy: ["czech", "koruna", "prague stock exchange", "česk", "koruny", "pražská burza", "čsú"],
        .globalEconomy: ["global economy", "world economy", "gdp", "recession", "imf ", "world bank", "growth outlook", "hdp", "recese", "ekonomik"],
    ]

    /// Cues are checked in this order; the first match wins and is shown to the user.
    static let rumourCues = ["reportedly", "rumor", "rumour", "people familiar", "sources say", "according to sources",
                             "is said to", "in talks", "considering a", "spekulac", "údajně", "podle zdrojů", "neoficiáln"]
    static let opinionCues = ["opinion", "column", "commentary", "editorial", "we think", "i think", "should ", "analysis ",
                              "názor", "komentář", "podle mého"]
    static let forecastCues = ["forecast", "expect", "projection", "outlook", "will likely", "estimate", "predict",
                               "prognóz", "očekáv", "odhad", "výhled"]

    public struct Classification: Sendable, Equatable {
        public var categories: [NewsCategory]
        public var statementType: StatementType
        public var cue: String?
        public var uncertainty: UncertaintyLevel
    }

    /// Lowercased text with punctuation (except `&` and `.`) turned into spaces, padded with spaces, so that
    /// keywords can be matched at word starts: `" " + keyword`. A trailing space in a keyword means "whole word".
    static func normalized(_ headline: String, _ summary: String?) -> String {
        let raw = (headline + " " + (summary ?? "")).lowercased()
        return " " + raw.replacingOccurrences(of: "[^\\p{L}\\p{N}&.]+", with: " ", options: .regularExpression) + " "
    }

    static func contains(_ text: String, _ keyword: String) -> Bool { text.contains(" " + keyword) }

    public static func classify(headline: String, summary: String?, isOfficial: Bool) -> Classification {
        let text = normalized(headline, summary)
        let categories = NewsCategory.allCases.filter { category in
            (categoryKeywords[category] ?? []).contains { contains(text, $0) }
        }
        if isOfficial {
            return Classification(categories: categories, statementType: .officialRelease, cue: nil, uncertainty: .low)
        }
        if let cue = rumourCues.first(where: { contains(text, $0) }) {
            return Classification(categories: categories, statementType: .rumour, cue: cue, uncertainty: .high)
        }
        if let cue = opinionCues.first(where: { contains(text, $0) }) {
            return Classification(categories: categories, statementType: .opinion, cue: cue, uncertainty: .high)
        }
        if let cue = forecastCues.first(where: { contains(text, $0) }) {
            return Classification(categories: categories, statementType: .forecast, cue: cue, uncertainty: .high)
        }
        return Classification(categories: categories, statementType: .reported, cue: nil, uncertainty: .medium)
    }

    /// Sector names associated with categories (used when no instrument matches).
    static let categorySectors: [NewsCategory: String] = [.energy: "Energy", .technology: "Information Technology",
                                                          .interestRates: "Financials", .centralBanks: "Financials"]

    public static func sectors(for categories: [NewsCategory]) -> [String] {
        Array(Set(categories.compactMap { categorySectors[$0] })).sorted()
    }
}

/// Deduplication (M-NEWS-2): items are one story when they share the canonical URL, or — published within
/// 48 hours — their headlines' word sets have Jaccard similarity ≥ 0.6, or one headline's words are ≥ 85 %
/// contained in the other's with at least 5 shared words (rewritten headlines). The earliest is kept and
/// other outlets are listed.
public enum NewsDeduplicator {
    public static let similarityThreshold = 0.6
    public static let containmentThreshold = 0.85
    public static let minimumSharedWords = 5
    public static let window: TimeInterval = 48 * 3600

    public static func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString.lowercased() }
        components.query = nil
        components.fragment = nil
        components.host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        var path = components.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        components.path = path
        components.scheme = "https"
        return components.string ?? url.absoluteString.lowercased()
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = words(a), right = words(b)
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    public static func isSameStory(_ a: String, _ b: String) -> Bool {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let shared = left.intersection(right).count
        let jaccard = Double(shared) / Double(left.union(right).count)
        let containment = Double(shared) / Double(min(left.count, right.count))
        return jaccard >= similarityThreshold || (containment >= containmentThreshold && shared >= minimumSharedWords)
    }

    /// Merges duplicates; input order does not matter, output is newest first.
    public static func merge(_ articles: [NewsArticle]) -> [NewsArticle] {
        var kept: [NewsArticle] = []
        for article in articles.sorted(by: { $0.publishedAt < $1.publishedAt }) {
            if let index = kept.firstIndex(where: { existing in
                existing.canonicalURL == article.canonicalURL
                    || (abs(existing.publishedAt.timeIntervalSince(article.publishedAt)) <= window
                        && isSameStory(existing.headline, article.headline))
            }) {
                let source = article.sourceName
                if source != kept[index].sourceName && !kept[index].alsoReportedBy.contains(source) {
                    kept[index].alsoReportedBy.append(source)
                }
                kept[index].relatedInstrumentIDs = Array(Set(kept[index].relatedInstrumentIDs + article.relatedInstrumentIDs))
                    .sorted { $0.string < $1.string }
            } else {
                kept.append(article)
            }
        }
        return kept.sorted { $0.publishedAt > $1.publishedAt }
    }
}

/// Finds instruments mentioned in a news item: provider symbols, or the company name (legal suffixes
/// removed) as whole words in the headline or summary.
public enum NewsInstrumentMatcher {
    public struct Candidate: Sendable {
        public var id: InstrumentID
        public var name: String
        public var tickers: [String]
        public var sector: String?
        public init(id: InstrumentID, name: String, tickers: [String], sector: String?) {
            self.id = id; self.name = name; self.tickers = tickers; self.sector = sector
        }
    }

    static let legalSuffixes = ["inc.", "inc", "corp.", "corp", "a.s.", "ag", "se", "plc", "n.v.", "s.a.", "ltd", "ucits", "etf", "(acc)", "(dist)"]

    static func coreName(_ name: String) -> String {
        var words = name.lowercased().split(separator: " ").map(String.init)
        while let last = words.last, legalSuffixes.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    public static func match(headline: String, summary: String?, symbols: [String], candidates: [Candidate]) -> [Candidate] {
        let text = " " + (headline + " " + (summary ?? "")).lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}&]+", with: " ",
                                                                                                options: .regularExpression) + " "
        let upperSymbols = Set(symbols.map { $0.uppercased() })
        return candidates.filter { candidate in
            if candidate.tickers.contains(where: { upperSymbols.contains($0.uppercased()) }) { return true }
            let core = coreName(candidate.name)
            return core.count >= 4 && text.contains(" \(core) ")
        }
    }
}
