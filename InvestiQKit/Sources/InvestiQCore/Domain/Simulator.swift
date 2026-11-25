import Foundation

/// Costs applied to simulated orders (FINANCIAL_METHODOLOGY §11, M-SIM). Commissions are charged in the
/// portfolio's base currency; currency conversions are automatic, as with many brokers, with a fee each way.
public struct FeeModel: Codable, Sendable, Hashable {
    /// Fixed commission per order (base currency).
    public var fixed: Decimal
    /// Commission as a fraction of the order value.
    public var percent: Decimal
    /// Minimum commission per order (base currency).
    public var minimum: Decimal
    /// Full bid–ask spread as a fraction; orders fill at mid ± spread/2.
    public var spread: Decimal
    /// Currency conversion fee as a fraction of the converted amount.
    public var fxFee: Decimal

    public init(fixed: Decimal, percent: Decimal, minimum: Decimal, spread: Decimal, fxFee: Decimal) {
        self.fixed = fixed; self.percent = percent; self.minimum = minimum; self.spread = spread; self.fxFee = fxFee
    }

    /// Defaults resemble a low-cost online broker: 0.1 % (min. 1 unit of base currency), 0.1 % spread,
    /// 0.25 % FX fee. Users can change every value.
    public static let standard = FeeModel(fixed: 0, percent: Decimal(string: "0.001")!, minimum: 1,
                                          spread: Decimal(string: "0.001")!, fxFee: Decimal(string: "0.0025")!)

    public func commission(onBaseValue value: Decimal) -> Decimal {
        max(minimum, fixed + percent * value).rounded(scale: 2)
    }

    // Decimals are stored as strings so that no JSON number ever passes through Double.
    private enum CodingKeys: String, CodingKey { case fixed, percent, minimum, spread, fxFee }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Decimal {
            let text = try container.decode(String.self, forKey: key)
            guard let decimal = DecimalSupport.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not a decimal")
            }
            return decimal
        }
        self.init(fixed: try value(.fixed), percent: try value(.percent), minimum: try value(.minimum), spread: try value(.spread),
                  fxFee: try value(.fxFee))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fixed.canonicalString, forKey: .fixed)
        try container.encode(percent.canonicalString, forKey: .percent)
        try container.encode(minimum.canonicalString, forKey: .minimum)
        try container.encode(spread.canonicalString, forKey: .spread)
        try container.encode(fxFee.canonicalString, forKey: .fxFee)
    }
}

public enum SimulatorMode: String, Codable, Sendable, CaseIterable {
    /// Current (delayed) market data; trades are dated today.
    case live
    /// Replays history from a start date; the simulated date only moves forward and no later data is used.
    case historical
}

public struct SimulatorSession: Sendable, Hashable, Identifiable {
    public var portfolioID: PortfolioID
    public var mode: SimulatorMode
    public var startDate: LocalDate
    public var simDate: LocalDate
    public var startingCapital: Decimal
    public var currency: CurrencyCode
    public var feeModel: FeeModel
    public var benchmarkInstrumentID: InstrumentID?
    public var id: PortfolioID { portfolioID }

    public init(portfolioID: PortfolioID, mode: SimulatorMode, startDate: LocalDate, simDate: LocalDate, startingCapital: Decimal,
                currency: CurrencyCode, feeModel: FeeModel, benchmarkInstrumentID: InstrumentID?) {
        self.portfolioID = portfolioID; self.mode = mode; self.startDate = startDate; self.simDate = simDate
        self.startingCapital = startingCapital; self.currency = currency; self.feeModel = feeModel
        self.benchmarkInstrumentID = benchmarkInstrumentID
    }
}
