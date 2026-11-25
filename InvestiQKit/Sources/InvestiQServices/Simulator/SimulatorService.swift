import Foundation
import InvestiQCore
import InvestiQData
import InvestiQAnalytics
import InvestiQPersistence

public enum SimulatorError: Error, Equatable, Sendable {
    case invalidCapital
    case invalidStartDate
    case sessionNotFound
    case instrumentNotTradable
    case noPrice
    case noExchangeRate(CurrencyCode)
    case insufficientCash(available: Decimal, needed: Decimal)
    case insufficientQuantity(available: Decimal)
    case cannotMoveBackwards
    case notHistorical
    case ledger(PortfolioServiceError)
}

public struct SimulatorOverview: Sendable {
    public var portfolio: Portfolio
    public var session: SimulatorSession
}

public struct SimulatorReport: Sendable {
    public var snapshot: PortfolioSnapshot
    public var valueBase: Decimal?
    public var cashBase: Decimal?
    public var benchmarkValueBase: Decimal?
    public var benchmarkName: String?
    public var costsBase: Decimal
    public var tradeCount: Int
    public var insights: [SimulatorInsight]
}

/// Paper trading (spec §22, M-SIM). Virtual portfolios only; fees, spreads, FX and data delays apply;
/// historical sessions never see data after their simulated date.
public actor SimulatorService {
    /// Historical sessions must start at least this many days in the past.
    public static let minimumHistoricalLookbackDays = 30

    private let store: DatabaseStore
    private let portfolios: PortfolioService
    private let instruments: InstrumentService
    private let marketData: MarketDataService
    private let exchangeRates: ExchangeRateService
    private let clock: any TimeProvider

    public init(store: DatabaseStore, portfolios: PortfolioService, instruments: InstrumentService, marketData: MarketDataService,
                exchangeRates: ExchangeRateService, clock: any TimeProvider) {
        self.store = store; self.portfolios = portfolios; self.instruments = instruments; self.marketData = marketData
        self.exchangeRates = exchangeRates; self.clock = clock
    }

    // MARK: Sessions

    public func createSession(name: String, mode: SimulatorMode, startingCapital: Decimal, currency: CurrencyCode,
                              startDate: LocalDate?, fees: FeeModel = .standard, benchmark: InstrumentID?) async throws -> SimulatorOverview {
        guard startingCapital > 0 else { throw SimulatorError.invalidCapital }
        let today = clock.today()
        let start: LocalDate
        switch mode {
        case .live: start = today
        case .historical:
            guard let startDate, startDate <= today.adding(days: -Self.minimumHistoricalLookbackDays) else { throw SimulatorError.invalidStartDate }
            start = startDate
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(trimmed.count) else { throw SimulatorError.ledger(.invalidName) }
        let now = clock.now()
        let portfolio = Portfolio(name: trimmed, kind: .virtual, baseCurrency: currency, createdAt: now)
        let deposit = Transaction(portfolioID: portfolio.id, type: .deposit, tradeDate: start, amount: startingCapital, currency: currency,
                                  source: .simulator, createdAt: now)
        let session = SimulatorSession(portfolioID: portfolio.id, mode: mode, startDate: start, simDate: start,
                                       startingCapital: startingCapital, currency: currency, feeModel: fees, benchmarkInstrumentID: benchmark)
        try await store.write { db in
            try PortfolioRecords.insert(portfolio, in: db)
            try TransactionRecords.insert(deposit, in: db)
            try SimulatorRecords.insert(session, in: db)
        }
        return SimulatorOverview(portfolio: portfolio, session: session)
    }

    public func sessions() async throws -> [SimulatorOverview] {
        try await store.read { db in
            try SimulatorRecords.all(in: db).compactMap { session in
                try PortfolioRecords.portfolio(session.portfolioID, in: db).map { SimulatorOverview(portfolio: $0, session: session) }
            }
        }
    }

    public func session(_ id: PortfolioID) async throws -> SimulatorSession {
        guard let session = try await store.read({ try SimulatorRecords.session(id, in: $0) }) else { throw SimulatorError.sessionNotFound }
        return session
    }

    /// The date trades are made on and prices are taken from.
    func tradingDate(_ session: SimulatorSession) -> LocalDate {
        session.mode == .historical ? session.simDate : clock.today()
    }

    /// Moves a historical session forward; it can never go back (that would let past trades use later knowledge).
    public func advance(_ id: PortfolioID, to date: LocalDate) async throws -> SimulatorSession {
        var session = try await session(id)
        guard session.mode == .historical else { throw SimulatorError.notHistorical }
        guard date > session.simDate else { throw SimulatorError.cannotMoveBackwards }
        session.simDate = min(date, clock.today())
        let updated = session
        try await store.write { try SimulatorRecords.update(updated, in: $0) }
        return updated
    }

    public func updateFees(_ id: PortfolioID, fees: FeeModel) async throws {
        var session = try await session(id)
        session.feeModel = fees
        let updated = session
        try await store.write { try SimulatorRecords.update(updated, in: $0) }
    }

    // MARK: Prices

    /// Price of one unit at the session's date: the delayed quote in live mode, the last close on or before the
    /// simulated date in historical mode. Bond quotes (percent of face) are converted to the price of one bond.
    public func referencePrice(_ instrumentID: InstrumentID, session: SimulatorSession) async throws -> (Listing, Sourced<Decimal>) {
        guard let entry = try await instruments.entry(instrumentID), let listing = entry.listing else { throw SimulatorError.instrumentNotTradable }
        let factor = try await instruments.bondDetails(instrumentID)?.quoteToUnitFactor ?? 1
        switch session.mode {
        case .live:
            guard let quote = await marketData.quote(for: listing).value else { throw SimulatorError.noPrice }
            return (listing, quote.map { $0.price * factor })
        case .historical:
            let date = session.simDate
            let range = DateRange(start: date.adding(days: -14), end: date)
            guard let history = await marketData.history(for: listing, range: range).value,
                  let bar = history.value.close(onOrBefore: date, maxCarryDays: 7) else { throw SimulatorError.noPrice }
            var metadata = history.metadata
            metadata.marketTimestamp = bar.date.startOfDay(in: TimeZone(identifier: "UTC") ?? .current)
            return (listing, Sourced(bar.close * factor, metadata: metadata))
        }
    }

    func rate(_ currency: CurrencyCode, to base: CurrencyCode, on date: LocalDate) async throws -> Decimal {
        if currency == base { return 1 }
        guard let rate = await exchangeRates.rate(from: currency, to: base, on: date).value?.value else {
            throw SimulatorError.noExchangeRate(currency)
        }
        return rate
    }

    public func preview(_ id: PortfolioID, instrumentID: InstrumentID, side: OrderSide, quantity: Decimal) async throws -> (OrderPreview, Sourced<Decimal>) {
        let session = try await session(id)
        let (listing, price) = try await referencePrice(instrumentID, session: session)
        let rate = try await rate(listing.tradingCurrency, to: session.currency, on: tradingDate(session))
        guard let preview = SimulatorEngine.preview(side: side, quantity: quantity, referencePrice: price.value,
                                                    tradeCurrency: listing.tradingCurrency, baseCurrency: session.currency,
                                                    rateToBase: rate, fees: session.feeModel) else { throw SimulatorError.noPrice }
        return (preview, price)
    }

    // MARK: Orders

    @discardableResult
    public func place(_ id: PortfolioID, instrumentID: InstrumentID, side: OrderSide, quantity: Decimal) async throws -> OrderPreview {
        let session = try await session(id)
        let (preview, _) = try await preview(id, instrumentID: instrumentID, side: side, quantity: quantity)
        guard let listing = try await instruments.entry(instrumentID)?.listing else { throw SimulatorError.instrumentNotTradable }
        let date = tradingDate(session)
        let snapshot = try await portfolios.snapshot(id, asOf: session.mode == .historical ? date : nil)
        let base = session.currency
        let trade = listing.tradingCurrency
        let now = clock.now()
        var transactions: [Transaction] = []
        // Exact trade value (no rounding) so that converted cash and the purchase net to zero in the ledger.
        let exactValue = quantity * preview.fillPrice
        switch side {
        case .buy:
            let available = snapshot.ledger.cash[base] ?? 0
            guard available >= preview.netCashBase else {
                throw SimulatorError.insufficientCash(available: available, needed: preview.netCashBase)
            }
            if trade != base {
                transactions.append(Transaction(portfolioID: id, type: .fxConversion, tradeDate: date, amount: (exactValue * preview.rateToBase).rounded(scale: 2),
                                                currency: base, fees: preview.fxFeeBase, counterCurrency: trade, counterAmount: exactValue,
                                                source: .simulator, createdAt: now))
            }
            transactions.append(Transaction(portfolioID: id, type: .buy, instrumentID: instrumentID, listingID: listing.id, tradeDate: date,
                                            quantity: quantity, price: preview.fillPrice, currency: trade, fees: preview.commissionBase,
                                            feeCurrency: trade == base ? nil : base, fxRateToBase: trade == base ? nil : preview.rateToBase,
                                            source: .simulator, createdAt: now.addingTimeInterval(0.001)))
        case .sell:
            let held = snapshot.ledger.positions[PositionKey(instrumentID: instrumentID, currency: trade)]?.quantity ?? 0
            guard held >= quantity else { throw SimulatorError.insufficientQuantity(available: held) }
            transactions.append(Transaction(portfolioID: id, type: .sell, instrumentID: instrumentID, listingID: listing.id, tradeDate: date,
                                            quantity: quantity, price: preview.fillPrice, currency: trade, fees: preview.commissionBase,
                                            feeCurrency: trade == base ? nil : base, fxRateToBase: trade == base ? nil : preview.rateToBase,
                                            source: .simulator, createdAt: now))
            if trade != base {
                let fxFeeInTrade = (exactValue * session.feeModel.fxFee).rounded(scale: 2)
                transactions.append(Transaction(portfolioID: id, type: .fxConversion, tradeDate: date, amount: exactValue, currency: trade,
                                                fees: fxFeeInTrade, counterCurrency: base,
                                                counterAmount: ((exactValue - fxFeeInTrade) * preview.rateToBase).rounded(scale: 2),
                                                source: .simulator, createdAt: now.addingTimeInterval(0.001)))
            }
        }
        do {
            try await portfolios.add(transactions)
        } catch let error as PortfolioServiceError {
            throw SimulatorError.ledger(error)
        }
        return preview
    }

    // MARK: Review

    public func report(_ id: PortfolioID) async throws -> SimulatorReport {
        let session = try await session(id)
        let end = tradingDate(session)
        let snapshot = try await portfolios.snapshot(id, asOf: session.mode == .historical ? end : nil)
        let transactions = try await portfolios.transactions(id)
        var trades: [SimulatorTrade] = []
        var costs: Decimal = 0
        var histories: [String: PriceSeries] = [:]
        for t in transactions {
            switch t.type {
            case .buy, .sell:
                guard let quantity = t.quantity, let price = t.price, let instrumentID = t.instrumentID else { continue }
                let rate = t.currency == session.currency ? 1 : (t.fxRateToBase ?? 0)
                let fees = t.fees * (t.feeCurrency == session.currency || t.currency == session.currency ? 1 : rate)
                costs += fees
                trades.append(SimulatorTrade(date: t.tradeDate, side: t.type == .buy ? .buy : .sell, instrumentKey: instrumentID.string,
                                             valueBase: quantity * price * rate, costsBase: fees))
                if t.type == .sell, histories[instrumentID.string] == nil, let listing = try await instruments.entry(instrumentID)?.listing,
                   let series = await marketData.history(for: listing, range: DateRange(start: session.startDate.adding(days: -120), end: end)).value {
                    histories[instrumentID.string] = series.value.asOf(end)
                }
            case .fxConversion:
                if t.currency == session.currency {
                    costs += t.fees
                } else if let amount = t.amount, let counter = t.counterAmount, amount > t.fees {
                    // Fee in the source currency, converted at the conversion's own implied rate.
                    costs += t.fees * counter / (amount - t.fees)
                }
            default:
                continue
            }
        }
        let total = snapshot.valuation.totalValueBase
        let weights: [(name: String, weight: Double)] = snapshot.valuation.holdings.compactMap { holding in
            guard let value = holding.marketValueBase, let total, total > 0 else { return nil }
            return (snapshot.instruments[holding.position.key.instrumentID]?.name ?? "", (value / total).doubleValue)
        }
        let cash = snapshot.valuation.cashBase
        let cashShare: Double? = { guard let cash, let total, total > 0 else { return nil }; return (cash / total).doubleValue }()
        let performance = try await portfolios.performance(id, from: session.startDate, to: end)
        let values = performance.points.compactMap(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Decimal(values.count)
        let insights = SimulatorReview.insights(trades: trades, startingCapital: session.startingCapital, start: session.startDate, end: end,
                                                averageValueBase: average, weights: weights, cashShare: cashShare, histories: histories)
        var benchmarkValue: Decimal?
        var benchmarkName: String?
        if let benchmarkID = session.benchmarkInstrumentID, let entry = try await instruments.entry(benchmarkID), let listing = entry.listing,
           let series = await marketData.history(for: listing, range: DateRange(start: session.startDate.adding(days: -14), end: end)).value {
            benchmarkName = entry.instrument.name
            let flows = transactions.compactMap { t -> BenchmarkReplay.Flow? in
                switch t.type {
                case .deposit: return t.amount.map { BenchmarkReplay.Flow(date: t.tradeDate, amountBase: $0) }
                case .withdrawal: return t.amount.map { BenchmarkReplay.Flow(date: t.tradeDate, amountBase: -$0) }
                default: return nil
                }
            }
            var rates: [String: Decimal] = [:]
            if series.value.currency != session.currency {
                for date in Set(flows.map(\.date) + [end]) {
                    rates[date.iso] = await exchangeRates.rate(from: series.value.currency, to: session.currency, on: date).value?.value
                }
            }
            let table = rates
            benchmarkValue = BenchmarkReplay.value(flows: flows, series: series.value.asOf(end), baseCurrency: session.currency, end: end,
                                                   fees: session.feeModel, rate: { _, date in table[date.iso] })
        }
        return SimulatorReport(snapshot: snapshot, valueBase: total, cashBase: cash, benchmarkValueBase: benchmarkValue,
                               benchmarkName: benchmarkName, costsBase: costs.rounded(scale: 2), tradeCount: trades.count, insights: insights)
    }

    // MARK: Strategy lab

    public struct StrategyRequest: Sendable {
        public var weights: [(InstrumentID, Double)]
        public var initial: Double
        public var monthly: Double
        public var start: LocalDate
        public var end: LocalDate
        public var rebalancing: StrategyBacktest.Rebalancing
        public var fees: FeeModel
        public var baseCurrency: CurrencyCode
        public var benchmark: InstrumentID?
        public init(weights: [(InstrumentID, Double)], initial: Double, monthly: Double, start: LocalDate, end: LocalDate,
                    rebalancing: StrategyBacktest.Rebalancing, fees: FeeModel, baseCurrency: CurrencyCode, benchmark: InstrumentID?) {
            self.weights = weights; self.initial = initial; self.monthly = monthly; self.start = start; self.end = end
            self.rebalancing = rebalancing; self.fees = fees; self.baseCurrency = baseCurrency; self.benchmark = benchmark
        }
    }

    public func backtest(_ request: StrategyRequest) async throws -> (strategy: StrategyBacktest.Result, benchmark: StrategyBacktest.Result?) {
        let end = min(request.end, clock.today())
        func asset(_ id: InstrumentID, _ weight: Double) async throws -> StrategyBacktest.Asset {
            guard let entry = try await instruments.entry(id), let listing = entry.listing,
                  let series = await marketData.history(for: listing, range: DateRange(start: request.start.adding(days: -14), end: end)).value
            else { throw SimulatorError.noPrice }
            let factor = try await instruments.bondDetails(id)?.quoteToUnitFactor ?? 1
            return StrategyBacktest.Asset(key: id.string, name: entry.instrument.name, targetWeight: weight,
                                          series: series.value.scaled(by: factor).asOf(end))
        }
        var assets: [StrategyBacktest.Asset] = []
        for (id, weight) in request.weights where weight > 0 { assets.append(try await asset(id, weight)) }
        var benchmarkAsset: StrategyBacktest.Asset?
        if let benchmark = request.benchmark { benchmarkAsset = try await asset(benchmark, 1) }
        // Monthly FX table (first day of each month), looked up as of each date (no later rates are used).
        var table: [CurrencyCode: [(LocalDate, Double)]] = [:]
        let currencies = Set((assets + [benchmarkAsset].compactMap { $0 }).map(\.series.currency)).subtracting([request.baseCurrency])
        for currency in currencies {
            var date = LocalDate(year: request.start.year, month: request.start.month, day: 1) ?? request.start
            var rows: [(LocalDate, Double)] = []
            while date <= end {
                let lookup = max(date, request.start)
                if let rate = await exchangeRates.rate(from: currency, to: request.baseCurrency, on: lookup).value?.value {
                    rows.append((lookup, rate.doubleValue))
                }
                date = date.adding(months: 1)
            }
            table[currency] = rows
        }
        let frozen = table
        let rate: @Sendable (CurrencyCode, LocalDate) -> Double? = { currency, date in
            frozen[currency]?.last(where: { $0.0 <= date })?.1
        }
        let strategy = try StrategyBacktest(assets: assets, baseCurrency: request.baseCurrency, fees: request.fees,
                                            rebalancing: request.rebalancing, rate: rate)
            .run(initial: request.initial, monthly: request.monthly, from: request.start, to: end)
        let benchmark = try benchmarkAsset.map {
            try StrategyBacktest(assets: [$0], baseCurrency: request.baseCurrency, fees: request.fees, rebalancing: .never, rate: rate)
                .run(initial: request.initial, monthly: request.monthly, from: request.start, to: end)
        }
        return (strategy, benchmark)
    }
}
