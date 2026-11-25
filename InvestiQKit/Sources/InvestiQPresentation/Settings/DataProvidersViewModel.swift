import Foundation
import Observation
import InvestiQCore
import InvestiQData
import InvestiQPersistence
import InvestiQServices

/// Settings → Data Providers (docs/DATA_PROVIDERS.md §5): enable, prioritise, enter keys (Keychain),
/// SEC contact e-mail, connection test.
@MainActor
@Observable
public final class DataProvidersViewModel {
    public struct Row: Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var coverageKey: String
        public var requiresKey: Bool
        public var hasKey: Bool
        public var enabled: Bool
        public var termsURL: URL?
        public var signupURL: URL?
        public var lastSuccess: Date?
        public var lastFailure: Date?
    }

    public private(set) var rows: [Row] = []
    public var secContactEmail = ""
    public private(set) var message: Message?
    public private(set) var testingProviderID: String?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var isDemo: Bool { app.isDemo }

    static let catalogue: [String: (name: String, coverage: String, terms: String?, signup: String?)] = [
        TwelveDataProvider.id: ("Twelve Data", "provider.coverage.twelvedata", "https://twelvedata.com/terms", "https://twelvedata.com/pricing"),
        AlphaVantageProvider.id: ("Alpha Vantage", "provider.coverage.alphavantage", "https://www.alphavantage.co/terms_of_service/", "https://www.alphavantage.co/support/#api-key"),
        FinnhubProvider.id: ("Finnhub", "provider.coverage.finnhub", "https://finnhub.io/terms-of-service", "https://finnhub.io/register"),
        MassiveProvider.id: ("Massive (formerly Polygon.io)", "provider.coverage.massive", "https://massive.com/terms", "https://massive.com/pricing"),
        FinancialModelingPrepProvider.id: ("Financial Modeling Prep", "provider.coverage.fmp", "https://site.financialmodelingprep.com/terms-of-service", "https://site.financialmodelingprep.com/developer/docs"),
        SECEdgarProvider.id: ("SEC EDGAR", "provider.coverage.secedgar", "https://www.sec.gov/os/accessing-edgar-data", nil),
        FREDProvider.id: ("FRED", "provider.coverage.fred", "https://fred.stlouisfed.org/docs/api/terms_of_use.html", "https://fred.stlouisfed.org/docs/api/api_key.html"),
        ECBExchangeRateProvider.id: ("European Central Bank", "provider.coverage.ecb", "https://www.ecb.europa.eu/services/disclaimer/html/index.en.html", nil),
        CNBExchangeRateProvider.id: ("Czech National Bank", "provider.coverage.cnb", "https://www.cnb.cz/en/terms-of-use/", nil),
    ]

    public func load() async {
        guard !isDemo, let services = app.services, let session = app.session else { return }
        let settings = Dictionary(uniqueKeysWithValues: app.preferences.providerSettings.map { ($0.id, $0) })
        let health = (try? await session.cacheStore.read { try CacheRecords.providerHealth(in: $0) }) ?? []
        let healthByID = Dictionary(uniqueKeysWithValues: health.map { ($0.providerID, $0) })
        let ordered = ProviderCatalog.allProviderIDs.sorted {
            (settings[$0]?.priority ?? ProviderCatalog.allProviderIDs.firstIndex(of: $0) ?? 0)
                < (settings[$1]?.priority ?? ProviderCatalog.allProviderIDs.firstIndex(of: $1) ?? 0)
        }
        rows = ordered.compactMap { id in
            guard let meta = Self.catalogue[id] else { return nil }
            return Row(id: id, name: meta.name, coverageKey: meta.coverage, requiresKey: ProviderCatalog.requiresKey.contains(id),
                       hasKey: services.credentials?.apiKey(for: id) != nil,
                       enabled: settings[id]?.enabled ?? ProviderCatalog.enabledByDefault.contains(id),
                       termsURL: meta.terms.flatMap(URL.init(string:)), signupURL: meta.signup.flatMap(URL.init(string:)),
                       lastSuccess: healthByID[id]?.lastSuccess, lastFailure: healthByID[id]?.lastFailure)
        }
        secContactEmail = app.preferences.secContactEmail ?? ""
    }

    private func persistSettings() async {
        let settings = rows.enumerated().map { ProviderSetting(id: $1.id, enabled: $1.enabled, priority: $0) }
        do {
            try await app.updatePreferences { $0.providerSettings = settings }
        } catch {
            message = Message("settings.error.saveFailed")
        }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].enabled = enabled
        await persistSettings()
    }

    public func move(_ id: String, by offset: Int) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), rows.count - 1)
        guard target != index else { return }
        rows.swapAt(index, target)
        await persistSettings()
    }

    /// Stores the key in the Keychain only; it is never shown again (docs/SECURITY.md §5).
    public func saveKey(_ key: String, for id: String) async {
        guard let credentials = app.services?.credentials else { return }
        do {
            try credentials.setAPIKey(key, for: id)
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].hasKey = !key.trimmingCharacters(in: .whitespaces).isEmpty
                if rows[index].hasKey { rows[index].enabled = true }
            }
            await persistSettings()
            app.reloadServices()
            message = Message("provider.keySaved")
        } catch {
            message = Message("provider.keySaveFailed")
        }
    }

    public func removeKey(for id: String) async { await saveKey("", for: id) }

    public var secEmailIsValid: Bool {
        let email = secContactEmail.trimmingCharacters(in: .whitespaces)
        return email.isEmpty || (email.contains("@") && email.contains(".") && !email.contains(" ") && email.count <= 254)
    }

    public func saveSECEmail() async {
        guard secEmailIsValid else { message = Message("provider.secEmailInvalid"); return }
        let email = secContactEmail.trimmingCharacters(in: .whitespaces)
        // Entering the contact e-mail is the explicit opt-in for SEC requests (and removing it opts out).
        if let index = rows.firstIndex(where: { $0.id == SECEdgarProvider.id }) { rows[index].enabled = !email.isEmpty }
        let settings = rows.enumerated().map { ProviderSetting(id: $1.id, enabled: $1.enabled, priority: $0) }
        do {
            try await app.updatePreferences {
                $0.secContactEmail = email.isEmpty ? nil : email
                $0.providerSettings = settings
            }
            message = Message(email.isEmpty ? "provider.secDisabled" : "provider.secSaved")
        } catch {
            message = Message("settings.error.saveFailed")
        }
    }

    /// Performs one small live request through the same decoders used in production.
    public func testConnection(_ id: String) async {
        guard let services = app.services else { return }
        testingProviderID = id
        defer { testingProviderID = nil }
        let today = app.environment.clock.today()
        do {
            if let provider = services.registry.exchangeRates.first(where: { $0.info.id == id }) {
                _ = try await provider.rates(base: .eur, quotes: [.czk], on: today)
            } else if let provider = services.registry.marketData.first(where: { $0.info.id == id }) {
                _ = try await provider.search("AAPL")
            } else if let provider = services.registry.fundamentals.first(where: { $0.info.id == id }) {
                let listing = ListingKey(mic: MIC(rawValue: "XNAS"), ticker: Ticker(rawValue: "AAPL")!)
                _ = try await provider.fundamentals(ProviderSymbol(providerID: id, symbol: "AAPL", listing: listing, currency: .usd))
            } else if let provider = services.registry.macro.first(where: { $0.info.id == id }) {
                _ = try await provider.series(id: "CPIAUCSL", range: DateRange(start: today.adding(months: -3), end: today))
            } else {
                message = Message("provider.testNotEnabled")
                return
            }
            message = Message("provider.testSucceeded")
        } catch {
            message = Message("provider.testFailed", [.key("provider.failure.\(ProviderFailureKey.key(error))")])
        }
        await load()
    }
}

/// Localisation suffix for provider failures (`provider.failure.*`).
public enum ProviderFailureKey {
    public static func key(_ error: any Error) -> String {
        switch error as? ProviderFailure {
        case .offline: return "offline"
        case .timedOut: return "timedOut"
        case .rateLimited: return "rateLimited"
        case .quotaExhausted: return "quotaExhausted"
        case .unauthorized: return "unauthorized"
        case .missingAPIKey: return "missingAPIKey"
        case .notSupported: return "notSupported"
        case .notFound: return "notFound"
        case .invalidResponse: return "invalidResponse"
        case .serverError: return "serverError"
        case .misconfigured: return "misconfigured"
        case .connectionFailed, .cancelled, nil: return "connectionFailed"
        }
    }
}
