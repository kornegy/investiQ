import Foundation

/// Fundamental metrics. Every field is optional; missing data is never zero (spec §13).
public struct FundamentalsSnapshot: Sendable, Hashable, Codable {
    public var currency: CurrencyCode?
    public var asOf: LocalDate?
    public var businessDescription: String?
    public var sector: String?
    public var industry: String?
    public var country: String?
    public var marketCapitalization: Decimal?
    public var sharesOutstanding: Decimal?
    public var revenueTTM: Decimal?
    public var revenueGrowthYoY: Decimal?
    public var netIncomeTTM: Decimal?
    public var epsTTM: Decimal?
    public var peRatio: Decimal?
    public var pbRatio: Decimal?
    public var freeCashFlowTTM: Decimal?
    public var debtToEquity: Decimal?
    public var operatingMargin: Decimal?
    public var profitMargin: Decimal?
    public var dividendYield: Decimal?
    public var dividendPerShare: Decimal?
    public var beta: Decimal?
    public var bookValuePerShare: Decimal?
    public var annualStatements: [FinancialStatementPeriod]

    public init(currency: CurrencyCode? = nil, asOf: LocalDate? = nil, businessDescription: String? = nil,
                sector: String? = nil, industry: String? = nil, country: String? = nil, marketCapitalization: Decimal? = nil,
                sharesOutstanding: Decimal? = nil, revenueTTM: Decimal? = nil, revenueGrowthYoY: Decimal? = nil,
                netIncomeTTM: Decimal? = nil, epsTTM: Decimal? = nil, peRatio: Decimal? = nil, pbRatio: Decimal? = nil,
                freeCashFlowTTM: Decimal? = nil, debtToEquity: Decimal? = nil, operatingMargin: Decimal? = nil,
                profitMargin: Decimal? = nil, dividendYield: Decimal? = nil, dividendPerShare: Decimal? = nil,
                beta: Decimal? = nil, bookValuePerShare: Decimal? = nil, annualStatements: [FinancialStatementPeriod] = []) {
        self.currency = currency
        self.asOf = asOf
        self.businessDescription = businessDescription
        self.sector = sector
        self.industry = industry
        self.country = country
        self.marketCapitalization = marketCapitalization
        self.sharesOutstanding = sharesOutstanding
        self.revenueTTM = revenueTTM
        self.revenueGrowthYoY = revenueGrowthYoY
        self.netIncomeTTM = netIncomeTTM
        self.epsTTM = epsTTM
        self.peRatio = peRatio
        self.pbRatio = pbRatio
        self.freeCashFlowTTM = freeCashFlowTTM
        self.debtToEquity = debtToEquity
        self.operatingMargin = operatingMargin
        self.profitMargin = profitMargin
        self.dividendYield = dividendYield
        self.dividendPerShare = dividendPerShare
        self.beta = beta
        self.bookValuePerShare = bookValuePerShare
        self.annualStatements = annualStatements
    }
}

/// One fiscal year of reported figures (e.g. from SEC EDGAR company facts).
public struct FinancialStatementPeriod: Sendable, Hashable, Codable {
    public var fiscalYear: Int
    public var periodEnd: LocalDate
    public var revenue: Decimal?
    public var operatingIncome: Decimal?
    public var netIncome: Decimal?
    public var eps: Decimal?
    public var operatingCashFlow: Decimal?
    public var capitalExpenditure: Decimal?
    public var totalDebt: Decimal?
    public var totalEquity: Decimal?
    public var dividendsPerShare: Decimal?

    public init(fiscalYear: Int, periodEnd: LocalDate, revenue: Decimal? = nil, operatingIncome: Decimal? = nil,
                netIncome: Decimal? = nil, eps: Decimal? = nil, operatingCashFlow: Decimal? = nil,
                capitalExpenditure: Decimal? = nil, totalDebt: Decimal? = nil, totalEquity: Decimal? = nil,
                dividendsPerShare: Decimal? = nil) {
        self.fiscalYear = fiscalYear
        self.periodEnd = periodEnd
        self.revenue = revenue
        self.operatingIncome = operatingIncome
        self.netIncome = netIncome
        self.eps = eps
        self.operatingCashFlow = operatingCashFlow
        self.capitalExpenditure = capitalExpenditure
        self.totalDebt = totalDebt
        self.totalEquity = totalEquity
        self.dividendsPerShare = dividendsPerShare
    }
}
