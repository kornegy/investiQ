import Foundation

/// News categories of spec §16.
public enum NewsCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case globalEconomy, centralBanks, interestRates, inflation, employment, corporateEarnings, geopolitics, energy,
         technology, regulation, europeanMarkets, usMarkets, czechEconomy
}

/// What kind of statement an item is (spec §16: distinguish facts from opinions, rumours and forecasts).
public enum StatementType: String, Codable, Sendable, CaseIterable, Hashable {
    /// Published by the institution itself (central bank, statistics office).
    case officialRelease
    /// Reported by a news outlet; not independently verified by InvestiQ.
    case reported
    case opinion
    case rumour
    case forecast
}

public enum UncertaintyLevel: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case low, medium, high
    public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

/// A processed news item. Only the headline and a short summary are kept — never the full article.
public struct NewsArticle: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var canonicalURL: String
    public var url: URL
    public var headline: String
    public var summary: String?
    public var sourceName: String
    /// Other outlets that published the same story (deduplicated).
    public var alsoReportedBy: [String]
    public var providerID: String
    public var publishedAt: Date
    /// Date of the underlying event when known (official releases: the publication date).
    public var eventDate: LocalDate?
    public var categories: [NewsCategory]
    public var statementType: StatementType
    /// The phrase that led to the statement type (shown so the classification is explainable).
    public var statementCue: String?
    public var uncertainty: UncertaintyLevel
    public var relatedInstrumentIDs: [InstrumentID]
    public var relatedSectors: [String]
    public var isDemo: Bool

    public init(id: String, canonicalURL: String, url: URL, headline: String, summary: String?, sourceName: String, alsoReportedBy: [String],
                providerID: String, publishedAt: Date, eventDate: LocalDate?, categories: [NewsCategory], statementType: StatementType,
                statementCue: String?, uncertainty: UncertaintyLevel, relatedInstrumentIDs: [InstrumentID], relatedSectors: [String], isDemo: Bool) {
        self.id = id; self.canonicalURL = canonicalURL; self.url = url; self.headline = headline; self.summary = summary
        self.sourceName = sourceName; self.alsoReportedBy = alsoReportedBy; self.providerID = providerID; self.publishedAt = publishedAt
        self.eventDate = eventDate; self.categories = categories; self.statementType = statementType; self.statementCue = statementCue
        self.uncertainty = uncertainty; self.relatedInstrumentIDs = relatedInstrumentIDs; self.relatedSectors = relatedSectors; self.isDemo = isDemo
    }
}

// MARK: - Economic calendar

public enum EconomicEventKind: String, Codable, Sendable, CaseIterable, Hashable {
    case centralBankDecision, inflationRelease, employmentReport, earningsReport, other
}

public enum EventStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Officially scheduled.
    case scheduled
    /// Published as tentative (for example FOMC dates until confirmed at the preceding meeting).
    case tentative
    case rescheduled
    case cancelled
    case released
}

/// A scheduled event with its time zone. `time` is `nil` when the source gives no time — never guessed.
public struct EconomicEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: EconomicEventKind
    /// Publishing institution or company (e.g. "ECB", "Fed", "ČNB", "Eurostat", "ČSÚ", "BLS").
    public var institution: String
    public var region: String
    public var date: LocalDate
    /// "HH:mm" in `timeZone`.
    public var time: String?
    public var timeZone: String
    public var status: EventStatus
    public var previousDate: LocalDate?
    /// Reference period of a statistic, e.g. "2026-11".
    public var referencePeriod: String?
    /// Localisation key of an extra note (e.g. "calendar.note.strategyOnly").
    public var noteKey: String?
    public var sourceURL: URL?
    public var verifiedOn: LocalDate?
    public var instrumentID: InstrumentID?
    public var symbol: String?

    public init(id: String, kind: EconomicEventKind, institution: String, region: String, date: LocalDate, time: String?, timeZone: String,
                status: EventStatus, previousDate: LocalDate? = nil, referencePeriod: String? = nil, noteKey: String? = nil,
                sourceURL: URL? = nil, verifiedOn: LocalDate? = nil, instrumentID: InstrumentID? = nil, symbol: String? = nil) {
        self.id = id; self.kind = kind; self.institution = institution; self.region = region; self.date = date; self.time = time
        self.timeZone = timeZone; self.status = status; self.previousDate = previousDate; self.referencePeriod = referencePeriod
        self.noteKey = noteKey; self.sourceURL = sourceURL; self.verifiedOn = verifiedOn; self.instrumentID = instrumentID; self.symbol = symbol
    }

    /// Exact instant when a time is known; otherwise `nil` (the event is shown as date-only).
    public var instant: Date? {
        guard let time, let zone = TimeZone(identifier: timeZone) else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: parts[0], minute: parts[1]))
    }
}
