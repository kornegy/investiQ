import Foundation
import InvestiQCore

/// Synthetic, clearly labelled demo news and earnings dates (ADR-008). Links use the reserved `.invalid`
/// domain and are never opened.
public struct DemoNewsProvider: NewsProvider, EarningsCalendarProvider {
    public static let providerID = "demo-news"
    public let info = ProviderInfo(id: DemoNewsProvider.providerID, name: "Demo news (synthetic)", capabilities: [.news, .earningsCalendar],
                                   limits: ProviderLimits(requestsPerMinute: 1_000), requiresAPIKey: false, quoteDelay: .synthetic,
                                   termsURL: nil, signupURL: nil, coverageKey: "provider.coverage.demo")
    private let clock: any TimeProvider

    public init(clock: any TimeProvider) { self.clock = clock }

    /// (hours ago, source, headline, summary, symbols)
    static let items: [(Double, String, String, String, [String])] = [
        (2, "Demo Central Bank", "Demo Central Bank keeps its policy rate unchanged at 3.50 %",
         "The bank's board voted to leave the main rate unchanged and said future decisions will depend on incoming inflation data.", []),
        (5, "Demo Wire", "Demo Chips Inc. reports quarterly revenue up 12 % year on year",
         "The company published results for the third quarter; operating margin was slightly lower than a year earlier.", ["DEMOCHIP"]),
        (7, "Demo Daily", "Demo Chips Inc. quarterly revenue rises 12 % year on year, results show",
         "Revenue grew while the operating margin narrowed slightly.", ["DEMOCHIP"]),
        (9, "Demo Statistics Office", "Consumer prices rose 2.4 % year on year in October",
         "Inflation was driven mainly by food and energy prices according to the flash estimate.", []),
        (14, "Demo Markets Blog", "Opinion: why we think energy stocks look expensive",
         "A columnist argues that current valuations already reflect high oil prices.", []),
        (20, "Demo Wire", "Demo Industrie SE reportedly in talks to buy a competitor, people familiar say",
         "The company declined to comment on the reported discussions.", ["DEMOIND"]),
        (26, "Demo Research", "Economists expect unemployment to stay near 3 % next year, outlook shows",
         "The outlook is based on a survey of forecasters and is subject to revision.", []),
        (31, "Demo Regulator", "Supervisor publishes new guidance on disclosure of investment costs",
         "The guidance clarifies how firms should present ongoing charges to retail clients.", []),
        (40, "Demo Daily", "Euro area GDP grew 0.3 % in the third quarter",
         "Growth was supported by household consumption, according to the statistics office.", []),
    ]

    public func latestNews(symbols: [String], limit: Int) async throws -> [RawNewsItem] {
        let now = clock.now()
        return Self.items.enumerated().prefix(limit).map { index, item in
            RawNewsItem(providerID: info.id, headline: item.2, summary: item.3, url: URL(string: "https://demo.invalid/news/\(index + 1)")!,
                        sourceName: item.1, publishedAt: now.addingTimeInterval(-item.0 * 3600), relatedSymbols: item.4,
                        providerCategory: item.1.contains("Central Bank") || item.1.contains("Statistics") || item.1.contains("Regulator")
                            ? "official:demo" : nil, language: "en")
        }
    }

    public func earnings(range: DateRange) async throws -> [EarningsEvent] {
        let today = clock.today()
        return DemoUniverse.all.filter { $0.instrument.kind == .stock }.enumerated().compactMap { index, demo in
            let date = today.adding(days: 6 + index * 9)
            guard date >= range.start, date <= range.end else { return nil }
            return EarningsEvent(symbol: demo.listing.ticker.rawValue, date: date, hour: index % 2 == 0 ? "bmo" : "amc",
                                 epsEstimate: nil, epsActual: nil)
        }
    }
}
