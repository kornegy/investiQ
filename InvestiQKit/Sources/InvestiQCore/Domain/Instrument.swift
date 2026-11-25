import Foundation

public enum InstrumentKind: String, Codable, Sendable, CaseIterable {
    case stock
    case etf
    case governmentBond
    case corporateBond

    public var isBond: Bool { self == .governmentBond || self == .corporateBond }
}

/// A financial instrument (issuer-level identity). Trading venues are modelled as `Listing`s.
public struct Instrument: Identifiable, Hashable, Codable, Sendable {
    public var id: InstrumentID
    public var kind: InstrumentKind
    public var name: String
    public var isin: ISIN?
    public var figi: String?
    /// ISO 3166-1 alpha-2 country of the issuer/domicile, if known.
    public var country: String?
    public var sector: String?
    public var issuer: String?
    /// Currency of denomination (bonds) or reporting/primary trading currency (stocks/ETFs).
    public var currency: CurrencyCode
    /// Identifier of the data source that created the record (`manual`, `demo`, provider ID).
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: InstrumentID = InstrumentID(), kind: InstrumentKind, name: String, isin: ISIN? = nil,
                figi: String? = nil, country: String? = nil, sector: String? = nil, issuer: String? = nil,
                currency: CurrencyCode, source: String, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isin = isin
        self.figi = figi
        self.country = country
        self.sector = sector
        self.issuer = issuer
        self.currency = currency
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// An instrument traded on a venue in a currency. One instrument may have many listings (ADR-006).
public struct Listing: Identifiable, Hashable, Codable, Sendable {
    public var id: ListingID
    public var instrumentID: InstrumentID
    public var mic: MIC?
    public var ticker: Ticker
    public var tradingCurrency: CurrencyCode
    public var isPrimary: Bool
    /// Symbol of this listing in each provider's notation (`providerID → symbol`).
    public var providerSymbols: [String: String]

    public init(id: ListingID = ListingID(), instrumentID: InstrumentID, mic: MIC?, ticker: Ticker,
                tradingCurrency: CurrencyCode, isPrimary: Bool = false, providerSymbols: [String: String] = [:]) {
        self.id = id
        self.instrumentID = instrumentID
        self.mic = mic
        self.ticker = ticker
        self.tradingCurrency = tradingCurrency
        self.isPrimary = isPrimary
        self.providerSymbols = providerSymbols
    }

    /// Stable key for caches: `MIC:TICKER` or `?:TICKER` when the venue is unknown.
    public var key: ListingKey { ListingKey(mic: mic, ticker: ticker) }
}

public struct ListingKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var mic: MIC?
    public var ticker: Ticker
    public init(mic: MIC?, ticker: Ticker) { self.mic = mic; self.ticker = ticker }
    public var description: String { "\(mic?.rawValue ?? "?"):\(ticker.rawValue)" }
}

public struct Exchange: Hashable, Codable, Sendable {
    public var mic: MIC
    public var name: String
    public var country: String
    public var timeZoneIdentifier: String
    public init(mic: MIC, name: String, country: String, timeZoneIdentifier: String) {
        self.mic = mic; self.name = name; self.country = country; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct StockDetails: Hashable, Codable, Sendable {
    public var industry: String?
    public var businessDescription: String?
    public var fiscalYearEnd: String?
    public init(industry: String? = nil, businessDescription: String? = nil, fiscalYearEnd: String? = nil) {
        self.industry = industry; self.businessDescription = businessDescription; self.fiscalYearEnd = fiscalYearEnd
    }
}

public enum DayCountConvention: String, Codable, Sendable, CaseIterable {
    case thirty360US
    case thirtyE360
    case actual360
    case actual365Fixed
    case actualActualICMA
}

public enum BondIssuerType: String, Codable, Sendable, CaseIterable {
    case government, corporate, supranational, municipal
}

public struct CallDate: Hashable, Codable, Sendable {
    public var date: LocalDate
    /// Call price per 100 of face value.
    public var pricePercent: Decimal
    public init(date: LocalDate, pricePercent: Decimal) { self.date = date; self.pricePercent = pricePercent }
}

/// Contractual bond terms. Analytics live in `InvestiQAnalytics.BondMath`.
public struct BondDetails: Hashable, Codable, Sendable {
    public var issuerType: BondIssuerType
    /// Face (nominal) value of one bond in the instrument currency.
    public var faceValue: Decimal
    /// Annual coupon rate as a fraction (0.045 = 4.5 %).
    public var couponRate: Decimal
    /// Coupons per year: 0 (zero coupon), 1, 2, 4 or 12.
    public var couponFrequency: Int
    public var dayCount: DayCountConvention
    public var issueDate: LocalDate?
    public var firstCouponDate: LocalDate?
    public var maturityDate: LocalDate
    public var callSchedule: [CallDate]
    public var creditRating: String?
    public var ratingAgency: String?
    public var ratingDate: LocalDate?
    public var minimumDenomination: Decimal?
    public var seniority: String?

    public init(issuerType: BondIssuerType, faceValue: Decimal, couponRate: Decimal, couponFrequency: Int,
                dayCount: DayCountConvention, issueDate: LocalDate? = nil, firstCouponDate: LocalDate? = nil,
                maturityDate: LocalDate, callSchedule: [CallDate] = [], creditRating: String? = nil,
                ratingAgency: String? = nil, ratingDate: LocalDate? = nil, minimumDenomination: Decimal? = nil,
                seniority: String? = nil) {
        self.issuerType = issuerType
        self.faceValue = faceValue
        self.couponRate = couponRate
        self.couponFrequency = couponFrequency
        self.dayCount = dayCount
        self.issueDate = issueDate
        self.firstCouponDate = firstCouponDate
        self.maturityDate = maturityDate
        self.callSchedule = callSchedule
        self.creditRating = creditRating
        self.ratingAgency = ratingAgency
        self.ratingDate = ratingDate
        self.minimumDenomination = minimumDenomination
        self.seniority = seniority
    }

    public var isCallable: Bool { !callSchedule.isEmpty }
    public static let allowedFrequencies: Set<Int> = [0, 1, 2, 4, 12]
}

public enum ReplicationMethod: String, Codable, Sendable, CaseIterable { case physicalFull, physicalSampling, synthetic }
public enum DistributionPolicy: String, Codable, Sendable, CaseIterable { case accumulating, distributing }

/// A labelled weight (fraction 0…1) used for holdings, sector, country and currency allocations.
public struct WeightedItem: Hashable, Codable, Sendable {
    public var label: String
    public var weight: Decimal
    public init(label: String, weight: Decimal) { self.label = label; self.weight = weight }
}

public struct ETFDetails: Hashable, Codable, Sendable {
    public var manager: String?
    public var indexName: String?
    /// Total expense ratio as a fraction (0.0007 = 0.07 % p.a.).
    public var totalExpenseRatio: Decimal?
    public var assetsUnderManagement: Money?
    public var replication: ReplicationMethod?
    public var distribution: DistributionPolicy?
    public var isUCITS: Bool?
    public var domicile: String?
    public var kidURL: URL?
    public var topHoldings: [WeightedItem]
    public var geography: [WeightedItem]
    public var sectors: [WeightedItem]
    /// Look-through currency exposure of the underlying assets (not the trading currency).
    public var currencyExposure: [WeightedItem]
    public var trackingDifference: Decimal?
    public var trackingError: Decimal?
    public var asOf: LocalDate?
    public var source: String?

    public init(manager: String? = nil, indexName: String? = nil, totalExpenseRatio: Decimal? = nil,
                assetsUnderManagement: Money? = nil, replication: ReplicationMethod? = nil,
                distribution: DistributionPolicy? = nil, isUCITS: Bool? = nil, domicile: String? = nil,
                kidURL: URL? = nil, topHoldings: [WeightedItem] = [], geography: [WeightedItem] = [],
                sectors: [WeightedItem] = [], currencyExposure: [WeightedItem] = [],
                trackingDifference: Decimal? = nil, trackingError: Decimal? = nil, asOf: LocalDate? = nil,
                source: String? = nil) {
        self.manager = manager
        self.indexName = indexName
        self.totalExpenseRatio = totalExpenseRatio
        self.assetsUnderManagement = assetsUnderManagement
        self.replication = replication
        self.distribution = distribution
        self.isUCITS = isUCITS
        self.domicile = domicile
        self.kidURL = kidURL
        self.topHoldings = topHoldings
        self.geography = geography
        self.sectors = sectors
        self.currencyExposure = currencyExposure
        self.trackingDifference = trackingDifference
        self.trackingError = trackingError
        self.asOf = asOf
        self.source = source
    }
}
