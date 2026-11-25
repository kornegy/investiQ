import Foundation
import InvestiQCore

/// Deterministic pseudo-random generator (SplitMix64) so demo data is identical on every run.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    public mutating func nextGaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), .leastNonzeroMagnitude)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// One fictional instrument of the demo universe. All names start with "Demo" and all ISINs use
/// the unassigned country code "ZZ" so they can never be confused with real securities (ADR-008).
public struct DemoInstrument: Sendable, Hashable {
    public let instrument: Instrument
    public let listing: Listing
    public let annualDrift: Double
    public let annualVolatility: Double
    public let startPrice: Double
    public let seed: UInt64
    public let fundamentals: FundamentalsSnapshot?
    public let bond: BondDetails?
    public let etf: ETFDetails?
    /// Splits applied to the synthetic raw prices (the published series is split-adjusted).
    public let splits: [CorporateAction]
    public let dividendYield: Double
}

public enum DemoUniverse {
    /// Synthetic history starts here; demo data never extends beyond "today".
    public static let historyStart = LocalDate(year: 2014, month: 1, day: 2)!
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a structurally valid ISIN with the "ZZ" prefix and a correct check digit.
    public static func isin(_ body: String) -> ISIN {
        precondition(body.count == 9)
        for digit in 0...9 {
            if let isin = ISIN(rawValue: "ZZ\(body)\(digit)") { return isin }
        }
        preconditionFailure("no check digit for \(body)")
    }

    static func make(_ index: UInt64, kind: InstrumentKind, name: String, isinBody: String, country: String, sector: String?,
                     issuer: String? = nil, currency: CurrencyCode, mic: String, ticker: String, drift: Double, volatility: Double,
                     price: Double, dividendYield: Double = 0, fundamentals: FundamentalsSnapshot? = nil, bond: BondDetails? = nil,
                     etf: ETFDetails? = nil, splits: [(LocalDate, Int, Int)] = []) -> DemoInstrument {
        let instrumentID = InstrumentID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llu", index))!)
        let listingID = ListingID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012llu", index))!)
        let instrument = Instrument(id: instrumentID, kind: kind, name: name, isin: isin(isinBody), country: country, sector: sector,
                                    issuer: issuer ?? name, currency: currency, source: DataSourceInfo.demo.id, createdAt: createdAt)
        let listing = Listing(id: listingID, instrumentID: instrumentID, mic: MIC(rawValue: mic), ticker: Ticker(rawValue: ticker)!,
                              tradingCurrency: currency, isPrimary: true)
        let actions = splits.map { CorporateAction(instrumentID: instrumentID, listing: listing.key, effectiveDate: $0.0,
                                                   kind: $0.1 > $0.2 ? .split : .reverseSplit, ratioNumerator: $0.1, ratioDenominator: $0.2) }
        return DemoInstrument(instrument: instrument, listing: listing, annualDrift: drift, annualVolatility: volatility,
                              startPrice: price, seed: 0xD3_70 &+ index &* 7919, fundamentals: fundamentals, bond: bond, etf: etf,
                              splits: actions, dividendYield: dividendYield)
    }

    public static let all: [DemoInstrument] = [
        make(1, kind: .stock, name: "Demo Energie a.s.", isinBody: "DEM000001", country: "CZ", sector: "Utilities", currency: .czk,
             mic: "XPRA", ticker: "DEMOENE", drift: 0.05, volatility: 0.22, price: 640, dividendYield: 0.06,
             fundamentals: FundamentalsSnapshot(currency: .czk, businessDescription: nil, sector: "Utilities", country: "CZ",
                                                marketCapitalization: 340_000_000_000, sharesOutstanding: 538_000_000,
                                                revenueTTM: 290_000_000_000, revenueGrowthYoY: -0.04, netIncomeTTM: 31_000_000_000,
                                                epsTTM: 57.6, peRatio: 11.1, pbRatio: 1.9, freeCashFlowTTM: 24_000_000_000,
                                                debtToEquity: 0.62, operatingMargin: 0.17, profitMargin: 0.107, dividendYield: 0.06,
                                                dividendPerShare: 38, beta: 0.7)),
        make(2, kind: .stock, name: "Demo Banka a.s.", isinBody: "DEM000002", country: "CZ", sector: "Financials", currency: .czk,
             mic: "XPRA", ticker: "DEMOBNK", drift: 0.07, volatility: 0.25, price: 720, dividendYield: 0.07,
             fundamentals: FundamentalsSnapshot(currency: .czk, sector: "Financials", country: "CZ", marketCapitalization: 150_000_000_000,
                                                revenueTTM: 46_000_000_000, netIncomeTTM: 17_000_000_000, epsTTM: 89, peRatio: 9.8,
                                                pbRatio: 1.6, dividendYield: 0.07, beta: 1.0)),
        make(3, kind: .stock, name: "Demo Software AG", isinBody: "DEM000003", country: "DE", sector: "Information Technology", currency: .eur,
             mic: "XETR", ticker: "DEMOSW", drift: 0.10, volatility: 0.30, price: 82, dividendYield: 0.012,
             fundamentals: FundamentalsSnapshot(currency: .eur, sector: "Information Technology", country: "DE",
                                                marketCapitalization: 210_000_000_000, revenueTTM: 33_000_000_000, revenueGrowthYoY: 0.09,
                                                netIncomeTTM: 5_900_000_000, epsTTM: 5.1, peRatio: 34, pbRatio: 4.8,
                                                freeCashFlowTTM: 4_200_000_000, debtToEquity: 0.31, operatingMargin: 0.24,
                                                profitMargin: 0.18, dividendYield: 0.012, beta: 1.15)),
        make(4, kind: .stock, name: "Demo Industrie SE", isinBody: "DEM000004", country: "DE", sector: "Industrials", currency: .eur,
             mic: "XETR", ticker: "DEMOIND", drift: 0.04, volatility: 0.27, price: 95, dividendYield: 0.03,
             fundamentals: FundamentalsSnapshot(currency: .eur, sector: "Industrials", country: "DE", revenueTTM: 77_000_000_000,
                                                revenueGrowthYoY: 0.02, netIncomeTTM: 4_100_000_000, epsTTM: 5.2, peRatio: 18,
                                                debtToEquity: 1.4, operatingMargin: 0.08, dividendYield: 0.03)),
        make(5, kind: .stock, name: "Demo Consumer Inc.", isinBody: "DEM000005", country: "US", sector: "Consumer Staples", currency: .usd,
             mic: "XNYS", ticker: "DEMOCON", drift: 0.06, volatility: 0.17, price: 120, dividendYield: 0.025,
             fundamentals: FundamentalsSnapshot(currency: .usd, sector: "Consumer Staples", country: "US", marketCapitalization: 360_000_000_000,
                                                revenueTTM: 84_000_000_000, revenueGrowthYoY: 0.03, netIncomeTTM: 14_700_000_000, epsTTM: 6.2,
                                                peRatio: 24, pbRatio: 7.9, freeCashFlowTTM: 16_000_000_000, debtToEquity: 0.7,
                                                operatingMargin: 0.23, profitMargin: 0.175, dividendYield: 0.025, beta: 0.45)),
        make(6, kind: .stock, name: "Demo Chips Inc.", isinBody: "DEM000006", country: "US", sector: "Information Technology", currency: .usd,
             mic: "XNAS", ticker: "DEMOCHP", drift: 0.16, volatility: 0.48, price: 35, dividendYield: 0.002,
             fundamentals: FundamentalsSnapshot(currency: .usd, sector: "Information Technology", country: "US",
                                                revenueTTM: 61_000_000_000, revenueGrowthYoY: 0.62, netIncomeTTM: 29_000_000_000, epsTTM: 1.18,
                                                peRatio: 58, pbRatio: 31, debtToEquity: 0.22, operatingMargin: 0.54, beta: 1.8),
             splits: [(LocalDate(year: 2021, month: 7, day: 20)!, 4, 1), (LocalDate(year: 2024, month: 6, day: 10)!, 10, 1)]),
        make(7, kind: .stock, name: "Demo Pharma Corp.", isinBody: "DEM000007", country: "US", sector: "Health Care", currency: .usd,
             mic: "XNAS", ticker: "DEMOPHA", drift: 0.03, volatility: 0.33, price: 60, dividendYield: 0.0,
             fundamentals: FundamentalsSnapshot(currency: .usd, sector: "Health Care", country: "US", revenueTTM: 4_200_000_000,
                                                revenueGrowthYoY: -0.11, netIncomeTTM: -380_000_000, epsTTM: -1.9,
                                                freeCashFlowTTM: -520_000_000, debtToEquity: 2.6, operatingMargin: -0.06)),
        make(8, kind: .etf, name: "Demo World Equity UCITS ETF (Acc)", isinBody: "DEM000008", country: "IE", sector: nil,
             issuer: "Demo Asset Management", currency: .eur, mic: "XETR", ticker: "DEMOWLD", drift: 0.075, volatility: 0.15, price: 60,
             etf: ETFDetails(manager: "Demo Asset Management", indexName: "Demo Developed World Index", totalExpenseRatio: 0.002,
                             assetsUnderManagement: Money(42_000_000_000, .eur), replication: .physicalSampling,
                             distribution: .accumulating, isUCITS: true, domicile: "IE",
                             topHoldings: [WeightedItem(label: "Demo Chips Inc.", weight: 0.048), WeightedItem(label: "Demo Software AG", weight: 0.021),
                                           WeightedItem(label: "Demo Consumer Inc.", weight: 0.015)],
                             geography: [WeightedItem(label: "US", weight: 0.71), WeightedItem(label: "JP", weight: 0.06),
                                         WeightedItem(label: "GB", weight: 0.04), WeightedItem(label: "Other", weight: 0.19)],
                             sectors: [WeightedItem(label: "Information Technology", weight: 0.26), WeightedItem(label: "Financials", weight: 0.16),
                                       WeightedItem(label: "Health Care", weight: 0.11), WeightedItem(label: "Other", weight: 0.47)],
                             currencyExposure: [WeightedItem(label: "USD", weight: 0.72), WeightedItem(label: "JPY", weight: 0.06),
                                                WeightedItem(label: "EUR", weight: 0.08), WeightedItem(label: "Other", weight: 0.14)],
                             trackingDifference: -0.0009, trackingError: 0.0011, asOf: LocalDate(year: 2026, month: 10, day: 31),
                             source: DataSourceInfo.demo.name)),
        make(9, kind: .etf, name: "Demo Europe 600 UCITS ETF (Dist)", isinBody: "DEM000009", country: "IE", sector: nil,
             issuer: "Demo Asset Management", currency: .eur, mic: "XAMS", ticker: "DEMOEU", drift: 0.05, volatility: 0.16, price: 45,
             dividendYield: 0.03,
             etf: ETFDetails(manager: "Demo Asset Management", indexName: "Demo Europe 600 Index", totalExpenseRatio: 0.0007,
                             assetsUnderManagement: Money(8_000_000_000, .eur), replication: .physicalFull, distribution: .distributing,
                             isUCITS: true, domicile: "IE",
                             geography: [WeightedItem(label: "GB", weight: 0.22), WeightedItem(label: "FR", weight: 0.17),
                                         WeightedItem(label: "DE", weight: 0.14), WeightedItem(label: "CH", weight: 0.14),
                                         WeightedItem(label: "Other", weight: 0.33)],
                             currencyExposure: [WeightedItem(label: "EUR", weight: 0.52), WeightedItem(label: "GBP", weight: 0.22),
                                                WeightedItem(label: "CHF", weight: 0.14), WeightedItem(label: "Other", weight: 0.12)],
                             trackingDifference: -0.0004, asOf: LocalDate(year: 2026, month: 10, day: 31), source: DataSourceInfo.demo.name)),
        make(10, kind: .etf, name: "Demo US Treasury 7-10y UCITS ETF", isinBody: "DEM000010", country: "IE", sector: nil,
             issuer: "Demo Asset Management", currency: .usd, mic: "XLON", ticker: "DEMOUST", drift: 0.02, volatility: 0.07, price: 180,
             dividendYield: 0.035,
             etf: ETFDetails(manager: "Demo Asset Management", indexName: "Demo US Treasury 7-10 Year Index", totalExpenseRatio: 0.0007,
                             replication: .physicalSampling, distribution: .distributing, isUCITS: true, domicile: "IE",
                             geography: [WeightedItem(label: "US", weight: 1.0)], currencyExposure: [WeightedItem(label: "USD", weight: 1.0)],
                             asOf: LocalDate(year: 2026, month: 10, day: 31), source: DataSourceInfo.demo.name)),
        make(11, kind: .governmentBond, name: "Demo Czech Government 4.50 % 2030", isinBody: "DEM000011", country: "CZ",
             sector: "Government", issuer: "Demo Czech Republic", currency: .czk, mic: "XPRA", ticker: "DEMOCZGB30",
             drift: 0.0, volatility: 0.04, price: 101.2,
             bond: BondDetails(issuerType: .government, faceValue: 10_000, couponRate: 0.045, couponFrequency: 1, dayCount: .actualActualICMA,
                               issueDate: LocalDate(year: 2020, month: 11, day: 11), maturityDate: LocalDate(year: 2030, month: 11, day: 11)!,
                               creditRating: "AA-", ratingAgency: "Demo Ratings", minimumDenomination: 10_000, seniority: "Senior unsecured")),
        make(12, kind: .governmentBond, name: "Demo Euro Government 2.00 % 2032", isinBody: "DEM000012", country: "DE",
             sector: "Government", issuer: "Demo Federal Republic", currency: .eur, mic: "XETR", ticker: "DEMODEGB32",
             drift: 0.0, volatility: 0.05, price: 97.4,
             bond: BondDetails(issuerType: .government, faceValue: 1_000, couponRate: 0.02, couponFrequency: 1, dayCount: .actualActualICMA,
                               issueDate: LocalDate(year: 2022, month: 2, day: 15), maturityDate: LocalDate(year: 2032, month: 2, day: 15)!,
                               creditRating: "AAA", ratingAgency: "Demo Ratings", minimumDenomination: 1_000)),
        make(13, kind: .corporateBond, name: "Demo Industrie SE 5.25 % 2029", isinBody: "DEM000013", country: "DE", sector: "Industrials",
             issuer: "Demo Industrie SE", currency: .eur, mic: "XFRA", ticker: "DEMOIND29", drift: 0.0, volatility: 0.06, price: 102.8,
             bond: BondDetails(issuerType: .corporate, faceValue: 1_000, couponRate: 0.0525, couponFrequency: 2, dayCount: .thirtyE360,
                               issueDate: LocalDate(year: 2022, month: 6, day: 30), maturityDate: LocalDate(year: 2029, month: 6, day: 30)!,
                               callSchedule: [CallDate(date: LocalDate(year: 2027, month: 6, day: 30)!, pricePercent: 101)],
                               creditRating: "BBB", ratingAgency: "Demo Ratings", minimumDenomination: 1_000, seniority: "Senior unsecured")),
    ]

    public static func instrument(_ id: InstrumentID) -> DemoInstrument? { all.first { $0.instrument.id == id } }
    public static func instrument(listing: ListingKey) -> DemoInstrument? { all.first { $0.listing.key == listing } }
    public static func instrument(symbol: String) -> DemoInstrument? {
        all.first { $0.listing.ticker.rawValue == symbol.uppercased() || $0.instrument.isin?.rawValue == symbol.uppercased() }
    }

    /// Synthetic split-adjusted daily closes (weekdays) from `historyStart` through `today`.
    /// Equities/ETFs follow geometric Brownian motion; bonds mean-revert around par and pull to 100 at maturity.
    public static func history(for demo: DemoInstrument, through today: LocalDate) -> [PriceBar] {
        var generator = SeededGenerator(seed: demo.seed)
        let dt = 1.0 / 252
        var price = demo.startPrice
        var bars: [PriceBar] = []
        var date = historyStart
        var previous = price
        while date <= today {
            if !date.isWeekend {
                let shock = generator.nextGaussian()
                if let bond = demo.bond {
                    // Mean reversion towards a target that converges to par as maturity approaches.
                    let yearsLeft = max(0, Double(date.days(to: bond.maturityDate)) / 365.25)
                    let target = 100 + (demo.startPrice - 100) * min(1, yearsLeft / 8)
                    price += 0.02 * (target - price) + demo.annualVolatility * 100 * dt.squareRoot() * shock * 0.3
                    if date >= bond.maturityDate { break }
                } else {
                    let drift = (demo.annualDrift - 0.5 * demo.annualVolatility * demo.annualVolatility) * dt
                    price *= exp(drift + demo.annualVolatility * dt.squareRoot() * shock)
                }
                let close = (price * 100).rounded() / 100
                let high = max(close, previous) * (1 + abs(generator.nextGaussian()) * 0.004)
                let low = min(close, previous) * (1 - abs(generator.nextGaussian()) * 0.004)
                let volume = demo.bond == nil ? (200_000 + abs(generator.nextGaussian()) * 150_000).rounded() : (500 + abs(generator.nextGaussian()) * 400).rounded()
                bars.append(PriceBar(date: date, open: Decimal(finite: (previous * 100).rounded() / 100),
                                     high: Decimal(finite: (high * 100).rounded() / 100), low: Decimal(finite: (low * 100).rounded() / 100),
                                     close: Decimal(finite: close) ?? 0, volume: Decimal(finite: volume)))
                previous = close
            }
            date = date.adding(days: 1)
        }
        return bars
    }

    /// Synthetic EUR-based FX reference rates (units per 1 EUR), deterministic per date.
    public static func euroRate(_ currency: CurrencyCode, on date: LocalDate) -> Decimal? {
        let anchors: [CurrencyCode: Double] = [.eur: 1, .czk: 25.1, .usd: 1.09, .gbp: 0.86, .chf: 0.95, .pln: 4.3]
        guard let anchor = anchors[currency] else { return nil }
        guard currency != .eur else { return 1 }
        // Smooth deterministic wobble: ±3 % over long cycles.
        let t = Double(date.daysSinceEpoch)
        let wobble = 1 + 0.03 * sin(t / 97 + Double(currency.rawValue.unicodeScalars.first!.value)) + 0.004 * sin(t / 7)
        return Decimal(finite: (anchor * wobble * 10_000).rounded() / 10_000)
    }
}
