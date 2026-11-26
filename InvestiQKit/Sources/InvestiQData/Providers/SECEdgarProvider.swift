import Foundation
import InvestiQCore

/// SEC EDGAR XBRL company facts (US filers). No key, but the SEC requires a User-Agent with a contact
/// e-mail and limits clients to 10 requests/second. The provider stays disabled until the user enters
/// their contact address (privacy — docs/DATA_PROVIDERS.md §5).
public struct SECEdgarProvider: FundamentalsProvider {
    public static let id = "secedgar"
    static let tickersURL = "https://www.sec.gov/files/company_tickers.json"
    static let factsBase = "https://data.sec.gov/api/xbrl/companyfacts"
    /// Company-facts documents of large filers are several MB.
    static let maximumFactsBytes = 30 * 1024 * 1024

    public let info = ProviderInfo(
        id: id, name: "SEC EDGAR",
        capabilities: [.fundamentals],
        limits: ProviderLimits(requestsPerMinute: 120),
        requiresAPIKey: false, quoteDelay: .endOfDay,
        termsURL: URL(string: "https://www.sec.gov/os/accessing-edgar-data"),
        signupURL: nil, coverageKey: "provider.coverage.secedgar")

    private let gateway: ProviderGateway
    private let clock: any TimeProvider
    private let contactEmail: String?

    public init(gateway: ProviderGateway, clock: any TimeProvider, contactEmail: String?) {
        self.gateway = gateway
        self.clock = clock
        self.contactEmail = contactEmail
    }

    private var headers: [String: String] {
        get throws {
            guard let email = contactEmail, email.contains("@"), !email.contains(" ") else {
                throw ProviderFailure.misconfigured("SEC contact e-mail required")
            }
            return ["User-Agent": "InvestiQ (personal research) \(email)"]
        }
    }

    /// Resolves a US ticker to its 10-digit CIK.
    func cik(for ticker: String) async throws -> String {
        struct Entry: Decodable { let cik_str: Int; let ticker: String }
        // Force unwrap is safe: `tickersURL` is a compile-time constant valid URL.
        let data = try await gateway.fetch(HTTPRequest(url: URL(string: Self.tickersURL)!, headers: try headers,
                                                       maximumResponseBytes: Self.maximumFactsBytes), provider: info)
        let entries = try JSON.decode([String: Entry].self, from: data)
        guard let entry = entries.values.first(where: { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }) else {
            throw ProviderFailure.notFound
        }
        return String(format: "%010d", entry.cik_str)
    }

    public func fundamentals(_ symbol: ProviderSymbol) async throws -> Sourced<FundamentalsSnapshot> {
        let cik = try await cik(for: symbol.listing.ticker.rawValue)
        let url = try URLComponents.make(Self.factsBase, path: "/CIK\(cik).json", query: [:])
        let data = try await gateway.fetch(HTTPRequest(url: url, headers: try headers, maximumResponseBytes: Self.maximumFactsBytes),
                                           provider: info)
        let statements = try Self.annualStatements(from: data)
        guard let latest = statements.last else { throw ProviderFailure.notFound }
        let previous = statements.dropLast().last
        var snapshot = FundamentalsSnapshot(currency: .usd, asOf: latest.periodEnd, annualStatements: statements)
        snapshot.revenueTTM = latest.revenue
        snapshot.netIncomeTTM = latest.netIncome
        snapshot.epsTTM = latest.eps
        if let revenue = latest.revenue, let operating = latest.operatingIncome, revenue > 0 { snapshot.operatingMargin = operating / revenue }
        if let revenue = latest.revenue, let net = latest.netIncome, revenue > 0 { snapshot.profitMargin = net / revenue }
        if let cfo = latest.operatingCashFlow, let capex = latest.capitalExpenditure { snapshot.freeCashFlowTTM = cfo - capex }
        if let debt = latest.totalDebt, let equity = latest.totalEquity, equity > 0 { snapshot.debtToEquity = debt / equity }
        if let current = latest.revenue, let prior = previous?.revenue, prior > 0 { snapshot.revenueGrowthYoY = current / prior - 1 }
        return Sourced(snapshot, metadata: DataMetadata(source: info.source, retrievedAt: clock.now(),
                                                        marketTimestamp: latest.periodEnd.startOfDay(in: .current),
                                                        currency: .usd, delay: .endOfDay, quality: .validated))
    }

    struct Fact: Decodable {
        let start: String?, end: String, val: Double, fy: Int?, fp: String?, form: String?, filed: String?
    }

    struct Facts: Decodable {
        struct Concept: Decodable { let units: [String: [Fact]] }
        let facts: [String: [String: Concept]]
    }

    /// Annual (10-K, full-year) values per fiscal year; for duplicates the latest filing wins.
    static func annualStatements(from data: Data) throws -> [FinancialStatementPeriod] {
        try JSON.rejectNonJSON(data)
        let facts = try JSON.decode(Facts.self, from: data)
        let gaap = facts.facts["us-gaap"] ?? [:]

        /// Full-year duration facts (≈ 1 year) or instant facts, from annual reports.
        func annual(_ tags: [String], unit: String = "USD", instant: Bool = false) -> [Int: (Decimal, LocalDate)] {
            var result: [Int: (Decimal, LocalDate, String)] = [:]
            for tag in tags {
                for fact in gaap[tag]?.units[unit] ?? [] {
                    guard fact.form == "10-K" || fact.form == "10-K/A", fact.fp == "FY",
                          let end = LocalDate(iso: fact.end), let value = Decimal(finite: fact.val) else { continue }
                    if !instant {
                        guard let start = fact.start.flatMap(LocalDate.init(iso:)), (350...380).contains(start.days(to: end)) else { continue }
                    }
                    // Facts are keyed by the calendar year of the period end (a 10-K also repeats prior years).
                    let year = end.year
                    let filed = fact.filed ?? ""
                    if let existing = result[year], existing.2 >= filed { continue }
                    result[year] = (value, end, filed)
                }
                if !result.isEmpty { break } // first tag with data wins (tags are listed by preference)
            }
            return result.mapValues { ($0.0, $0.1) }
        }

        let revenue = annual(["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax", "SalesRevenueNet"])
        let operating = annual(["OperatingIncomeLoss"])
        let net = annual(["NetIncomeLoss"])
        let eps = annual(["EarningsPerShareDiluted", "EarningsPerShareBasic"], unit: "USD/shares")
        let cfo = annual(["NetCashProvidedByUsedInOperatingActivities"])
        let capex = annual(["PaymentsToAcquirePropertyPlantAndEquipment"])
        let debt = annual(["LongTermDebt", "LongTermDebtNoncurrent"], instant: true)
        let equity = annual(["StockholdersEquity"], instant: true)
        let dps = annual(["CommonStockDividendsPerShareDeclared"], unit: "USD/shares")

        let years = Set(revenue.keys).union(net.keys).sorted().suffix(6)
        return years.compactMap { year in
            guard let end = revenue[year]?.1 ?? net[year]?.1 else { return nil }
            return FinancialStatementPeriod(fiscalYear: year, periodEnd: end, revenue: revenue[year]?.0,
                                            operatingIncome: operating[year]?.0, netIncome: net[year]?.0, eps: eps[year]?.0,
                                            operatingCashFlow: cfo[year]?.0, capitalExpenditure: capex[year]?.0,
                                            totalDebt: debt[year]?.0, totalEquity: equity[year]?.0, dividendsPerShare: dps[year]?.0)
        }
    }
}
