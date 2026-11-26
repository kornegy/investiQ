import Foundation
import InvestiQCore

/// FRED (Federal Reserve Bank of St. Louis). Requires a free API key; some series are copyrighted by
/// third parties — the app preselects public-domain series only (docs/DATA_PROVIDERS.md).
/// FRED only accepts the key as a query parameter; it is redacted everywhere.
public struct FREDProvider: MacroeconomicDataProvider {
    public static let id = "fred"
    static let base = "https://api.stlouisfed.org/fred"

    /// Public-domain US series offered by default (BLS/BEA/Fed data).
    public static let defaultSeries = ["CPIAUCSL", "UNRATE", "FEDFUNDS", "DGS10"]

    public let info = ProviderInfo(
        id: id, name: "FRED (Federal Reserve Bank of St. Louis)",
        capabilities: [.macro],
        limits: ProviderLimits(requestsPerMinute: 60),
        requiresAPIKey: true, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://fred.stlouisfed.org/docs/api/terms_of_use.html"),
        signupURL: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html"),
        coverageKey: "provider.coverage.fred")

    private let gateway: ProviderGateway
    private let credentials: any CredentialSource
    private let clock: any TimeProvider

    public init(gateway: ProviderGateway, credentials: any CredentialSource, clock: any TimeProvider) {
        self.gateway = gateway
        self.credentials = credentials
        self.clock = clock
    }

    struct Response: Decodable {
        struct Observation: Decodable { let date: String; let value: String }
        let observations: [Observation]?
        let error_message: String?
    }

    public func series(id: String, range: DateRange) async throws -> Sourced<[MacroObservation]> {
        guard let key = credentials.apiKey(for: info.id) else { throw ProviderFailure.missingAPIKey }
        guard id.range(of: #"^[A-Za-z0-9_]{1,40}$"#, options: .regularExpression) != nil else {
            throw ProviderFailure.misconfigured("invalid FRED series id")
        }
        let url = try URLComponents.make(Self.base, path: "/series/observations", query: [
            "series_id": id, "api_key": key, "file_type": "json",
            "observation_start": range.start.iso, "observation_end": range.end.iso])
        let data: Data
        do {
            data = try await gateway.fetch(HTTPRequest(url: url), provider: info)
        } catch ProviderFailure.invalidResponse(let message) where message.contains("400") {
            throw ProviderFailure.unauthorized // FRED answers 400 for unregistered/invalid keys
        }
        try JSON.rejectNonJSON(data)
        let response = try JSON.decode(Response.self, from: data)
        if response.error_message != nil { throw ProviderFailure.invalidResponse("FRED error") }
        let observations = (response.observations ?? []).compactMap { item -> MacroObservation? in
            guard let date = LocalDate(iso: item.date) else { return nil }
            // "." marks a missing observation in FRED — kept as nil, never zero.
            return MacroObservation(date: date, value: item.value == "." ? nil : Double(item.value))
        }
        return Sourced(observations, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(), delay: .endOfDay,
                                                            quality: .unvalidated))
    }
}
