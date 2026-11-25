import Foundation
import InvestiQCore
import InvestiQData
import InvestiQSecurity
import InvestiQPersistence

/// The providers available to one session, ordered by user priority (docs/DATA_PROVIDERS.md §1).
public struct ProviderRegistry: Sendable {
    public let marketData: [any MarketDataProvider]
    public let fundamentals: [any FundamentalsProvider]
    public let exchangeRates: [any ExchangeRateProvider]
    public let macro: [any MacroeconomicDataProvider]
    public let news: [any NewsProvider]
    public let earnings: [any EarningsCalendarProvider]
    public let bonds: [any BondDataProvider]
    public let etfs: [any ETFDataProvider]

    public init(marketData: [any MarketDataProvider] = [], fundamentals: [any FundamentalsProvider] = [],
                exchangeRates: [any ExchangeRateProvider] = [], macro: [any MacroeconomicDataProvider] = [],
                news: [any NewsProvider] = [], earnings: [any EarningsCalendarProvider] = [],
                bonds: [any BondDataProvider] = [], etfs: [any ETFDataProvider] = []) {
        self.marketData = marketData
        self.fundamentals = fundamentals
        self.exchangeRates = exchangeRates
        self.macro = macro
        self.news = news
        self.earnings = earnings
        self.bonds = bonds
        self.etfs = etfs
    }

    /// Demo sessions only ever see the synthetic provider (ADR-008).
    public static func demo(clock: any TimeProvider) -> ProviderRegistry {
        let demo = DemoDataProvider(clock: clock)
        return ProviderRegistry(marketData: [demo], fundamentals: [demo], exchangeRates: [demo], macro: [demo], bonds: [demo], etfs: [demo])
    }

    public var isEmpty: Bool { marketData.isEmpty && exchangeRates.isEmpty }
}

/// Static catalogue of real providers shown in Settings → Data Providers.
public enum ProviderCatalog {
    public static let marketProviderIDs = [TwelveDataProvider.id, AlphaVantageProvider.id, FinnhubProvider.id,
                                           MassiveProvider.id, FinancialModelingPrepProvider.id]
    public static let allProviderIDs = marketProviderIDs + [SECEdgarProvider.id, FREDProvider.id, ECBExchangeRateProvider.id, CNBExchangeRateProvider.id]
    /// Providers that need no key and are enabled by default (public central-bank data).
    public static let enabledByDefault: Set<String> = [ECBExchangeRateProvider.id, CNBExchangeRateProvider.id]
    public static let requiresKey: Set<String> = [TwelveDataProvider.id, AlphaVantageProvider.id, FinnhubProvider.id, MassiveProvider.id,
                                                  FinancialModelingPrepProvider.id, FREDProvider.id]

    /// Builds the registry for a real profile from preferences and the keys stored in the Keychain.
    public static func makeRegistry(preferences: UserPreferences, credentials: any CredentialSource, gateway: ProviderGateway,
                                    clock: any TimeProvider) -> ProviderRegistry {
        let settings = Dictionary(uniqueKeysWithValues: preferences.providerSettings.map { ($0.id, $0) })
        func isEnabled(_ id: String) -> Bool {
            let enabled = settings[id]?.enabled ?? enabledByDefault.contains(id)
            return enabled && (!requiresKey.contains(id) || credentials.apiKey(for: id) != nil)
        }
        func priority(_ id: String) -> Int { settings[id]?.priority ?? (allProviderIDs.firstIndex(of: id) ?? 99) }

        var market: [any MarketDataProvider] = []
        var fundamentals: [any FundamentalsProvider] = []
        var news: [any NewsProvider] = []
        var earnings: [any EarningsCalendarProvider] = []
        var macro: [any MacroeconomicDataProvider] = []
        for id in allProviderIDs.sorted(by: { priority($0) < priority($1) }) where isEnabled(id) {
            switch id {
            case TwelveDataProvider.id: market.append(TwelveDataProvider(gateway: gateway, credentials: credentials, clock: clock))
            case AlphaVantageProvider.id:
                let provider = AlphaVantageProvider(gateway: gateway, credentials: credentials, clock: clock)
                market.append(provider); fundamentals.append(provider)
            case FinnhubProvider.id:
                let provider = FinnhubProvider(gateway: gateway, credentials: credentials, clock: clock)
                market.append(provider); fundamentals.append(provider); news.append(provider); earnings.append(provider)
            case MassiveProvider.id: market.append(MassiveProvider(gateway: gateway, credentials: credentials, clock: clock))
            case FinancialModelingPrepProvider.id:
                let provider = FinancialModelingPrepProvider(gateway: gateway, credentials: credentials, clock: clock)
                market.append(provider); fundamentals.append(provider)
            case SECEdgarProvider.id where preferences.secContactEmail != nil:
                fundamentals.append(SECEdgarProvider(gateway: gateway, clock: clock, contactEmail: preferences.secContactEmail))
            case FREDProvider.id: macro.append(FREDProvider(gateway: gateway, credentials: credentials, clock: clock))
            default: break
            }
        }
        // Exchange rates: CNB for CZK pairs (official Czech fixing), ECB for euro pairs.
        var rates: [any ExchangeRateProvider] = []
        if isEnabled(CNBExchangeRateProvider.id) { rates.append(CNBExchangeRateProvider(gateway: gateway, clock: clock)) }
        if isEnabled(ECBExchangeRateProvider.id) {
            let ecb = ECBExchangeRateProvider(gateway: gateway, clock: clock)
            rates.append(ecb)
            macro.append(ecb)
        }
        return ProviderRegistry(marketData: market, fundamentals: fundamentals, exchangeRates: rates, macro: macro,
                                news: news, earnings: earnings)
    }
}

/// Reads API keys for one profile from the secure store (account `profileID/providerID`).
public struct KeychainCredentials: CredentialSource {
    let store: any SecureStore
    let profileID: ProfileID
    public init(store: any SecureStore, profileID: ProfileID) { self.store = store; self.profileID = profileID }

    public func apiKey(for providerID: String) -> String? {
        guard let data = try? store.data(service: .apiKey, account: "\(profileID.string)/\(providerID)") else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func setAPIKey(_ key: String?, for providerID: String) throws {
        let account = "\(profileID.string)/\(providerID)"
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.set(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), service: .apiKey, account: account)
        } else {
            try store.remove(service: .apiKey, account: account)
        }
    }
}

/// Maps a listing to each provider's symbol notation.
public enum SymbolMapper {
    static let alphaVantageSuffix = ["XLON": "LON", "XETR": "DEX", "XFRA": "FRK", "XAMS": "AMS", "XPAR": "PAR"]
    static let usVenues: Set<String> = ["XNYS", "XNAS", "XNGS", "ARCX", "BATS", "XASE"]

    public static func symbol(for listing: Listing, providerID: String) -> ProviderSymbol? {
        if let stored = listing.providerSymbols[providerID] {
            return ProviderSymbol(providerID: providerID, symbol: stored, listing: listing.key, currency: listing.tradingCurrency)
        }
        let ticker = listing.ticker.rawValue
        let mic = listing.mic?.rawValue
        let symbol: String?
        switch providerID {
        case DemoDataProvider.id, TwelveDataProvider.id: symbol = ticker
        case AlphaVantageProvider.id:
            if let mic, let suffix = alphaVantageSuffix[mic] { symbol = "\(ticker).\(suffix)" } else { symbol = mic.map(usVenues.contains) == true ? ticker : nil }
        case FinnhubProvider.id, MassiveProvider.id, FinancialModelingPrepProvider.id, SECEdgarProvider.id:
            symbol = mic.map(usVenues.contains) == true ? ticker : nil
        default: symbol = nil
        }
        return symbol.map { ProviderSymbol(providerID: providerID, symbol: $0, listing: listing.key, currency: listing.tradingCurrency) }
    }
}

/// Persists provider outcomes into the cache database (drives the outage indicator).
public struct CacheHealthObserver: ProviderHealthObserver {
    let store: DatabaseStore
    public init(store: DatabaseStore) { self.store = store }

    public func recordSuccess(providerID: String, at date: Date) async {
        try? await store.write { try CacheRecords.recordProviderOutcome(providerID: providerID, success: true, failureKind: nil, at: date, in: $0) }
    }

    public func recordFailure(providerID: String, failure: ProviderFailure, at date: Date) async {
        let kind = String(describing: failure)
        try? await store.write { try CacheRecords.recordProviderOutcome(providerID: providerID, success: false, failureKind: kind, at: date, in: $0) }
    }
}
