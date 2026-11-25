import Foundation

public enum PortfolioKind: String, Codable, Sendable, CaseIterable {
    /// Real historical transactions entered by the user.
    case real
    /// Virtual (paper-trading/simulator) portfolio. Never mixed with real data.
    case virtual
}

public struct Portfolio: Identifiable, Hashable, Codable, Sendable {
    public var id: PortfolioID
    public var name: String
    public var kind: PortfolioKind
    public var baseCurrency: CurrencyCode
    public var createdAt: Date
    public var archived: Bool
    public var notes: String?

    public init(id: PortfolioID = PortfolioID(), name: String, kind: PortfolioKind, baseCurrency: CurrencyCode,
                createdAt: Date, archived: Bool = false, notes: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseCurrency = baseCurrency
        self.createdAt = createdAt
        self.archived = archived
        self.notes = notes
    }
}

public struct Watchlist: Identifiable, Hashable, Codable, Sendable {
    public var id: WatchlistID
    public var name: String
    public var createdAt: Date
    public var instrumentIDs: [InstrumentID]
    public init(id: WatchlistID = WatchlistID(), name: String, createdAt: Date, instrumentIDs: [InstrumentID] = []) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.instrumentIDs = instrumentIDs
    }
}
