import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import InvestiQCore

/// Press releases of official institutions via their public RSS feeds (no key). Only titles, short
/// descriptions and links are read; articles are never copied (spec §16).
public struct OfficialNewsProvider: NewsProvider {
    public struct Feed: Sendable, Hashable {
        public var id: String
        public var name: String
        public var url: URL
        public var language: String
    }

    /// Verified feed URLs (docs/DATA_PROVIDERS.md §News).
    public static let feeds: [Feed] = [
        Feed(id: "ecb", name: "European Central Bank", url: URL(string: "https://www.ecb.europa.eu/rss/press.xml")!, language: "en"),
        Feed(id: "fed", name: "Federal Reserve", url: URL(string: "https://www.federalreserve.gov/feeds/press_all.xml")!, language: "en"),
        Feed(id: "cnb", name: "Česká národní banka", url: URL(string: "https://www.cnb.cz/cs/.content/rss-feed/rss-feed_tz.rss")!, language: "cs"),
    ]
    public static let providerID = "official"
    /// Feed descriptions are cut to this length; the original is always linked.
    public static let summaryLimit = 300

    public let info = ProviderInfo(id: OfficialNewsProvider.providerID, name: "Official press releases (ECB, Fed, ČNB)",
                                   capabilities: [.news], limits: ProviderLimits(requestsPerMinute: 10), requiresAPIKey: false,
                                   quoteDelay: .endOfDay, termsURL: nil, signupURL: nil, coverageKey: "provider.coverage.official")
    private let gateway: ProviderGateway

    public init(gateway: ProviderGateway) { self.gateway = gateway }

    public func latestNews(symbols: [String], limit: Int) async throws -> [RawNewsItem] {
        var items: [RawNewsItem] = []
        var lastError: ProviderFailure?
        for feed in Self.feeds {
            do {
                let data = try await gateway.fetch(HTTPRequest(url: feed.url), provider: info)
                items += Self.parse(data, feed: feed).prefix(limit)
            } catch let failure as ProviderFailure {
                lastError = failure
            }
        }
        if items.isEmpty, let lastError { throw lastError }
        return items.sorted { $0.publishedAt > $1.publishedAt }
    }

    static func parse(_ data: Data, feed: Feed) -> [RawNewsItem] {
        let delegate = RSSParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items.compactMap { raw in
            guard let title = raw["title"].map(Self.plainText), !title.isEmpty,
                  let link = raw["link"]?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: link),
                  url.scheme == "https", let date = raw["pubDate"].flatMap(Self.rfc822) ?? raw["dc:date"].flatMap(Self.iso8601) else { return nil }
            let summary = raw["description"].map(Self.plainText).flatMap { $0.isEmpty ? nil : String($0.prefix(Self.summaryLimit)) }
            return RawNewsItem(providerID: providerID, headline: title, summary: summary, url: url, sourceName: feed.name, publishedAt: date,
                               relatedSymbols: [], providerCategory: "official:\(feed.id)", language: feed.language)
        }
    }

    /// Feeds are untrusted: markup is removed and entities decoded; nothing is rendered as HTML.
    static func plainText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rfc822(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        return nil
    }

    static func iso8601(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Collects <item> children (title, link, description, pubDate, dc:date) of an RSS 2.0 document.
final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [[String: String]] = []
    private var current: [String: String]?
    private var element = ""
    private var buffer = ""
    /// Feeds larger than this many items are truncated (resource limit for untrusted input).
    static let maximumItems = 200

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" { current = [:] }
        element = qName ?? elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        if name == "item" || elementName == "item" {
            if let current, items.count < Self.maximumItems { items.append(current) }
            current = nil
        } else if current != nil, ["title", "link", "description", "pubDate", "dc:date"].contains(name) {
            current?[name] = buffer
        }
        buffer = ""
    }
}
