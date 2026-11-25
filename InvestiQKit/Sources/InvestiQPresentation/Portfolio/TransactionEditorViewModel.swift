import Foundation
import Observation
import InvestiQCore
import InvestiQServices

/// Manual transaction entry (spec §21). Numbers are parsed with the user's locale and never
/// silently defaulted; the ledger re-validates the whole history before saving.
@MainActor
@Observable
public final class TransactionEditorViewModel {
    public var type: TransactionType = .buy
    public var date: Date
    public var instrumentID: InstrumentID?
    public var quantityText = ""
    public var priceText = ""
    public var amountText = ""
    public var currency: CurrencyCode
    public var feesText = ""
    public var feeInBaseCurrency = false
    public var taxText = ""
    public var accruedInterestText = ""
    public var fxRateText = ""
    public var counterCurrency: CurrencyCode = .eur
    public var counterAmountText = ""
    public var splitNumeratorText = ""
    public var splitDenominatorText = ""
    public var notes = ""
    public private(set) var instruments: [InstrumentEntry] = []
    public private(set) var error: Message?
    public private(set) var saved = false

    private let app: AppModel
    private let portfolio: Portfolio
    private let locale: Locale
    private let editing: Transaction?

    public init(app: AppModel, portfolio: Portfolio, editing: Transaction? = nil, locale: Locale = .current) {
        self.app = app
        self.portfolio = portfolio
        self.locale = locale
        self.editing = editing
        self.currency = portfolio.baseCurrency
        self.date = app.environment.clock.now()
        if let editing { populate(from: editing) }
    }

    public var baseCurrency: CurrencyCode { portfolio.baseCurrency }
    public var isVirtual: Bool { portfolio.kind == .virtual }

    public func load() async {
        instruments = (try? await app.services?.instruments.library()) ?? []
    }

    /// Which fields the current type uses.
    public var usesInstrument: Bool { type.requiresInstrument || type == .fee }
    public var usesQuantityAndPrice: Bool { [.buy, .sell, .bondRedemption].contains(type) }
    public var usesAmount: Bool { ![.buy, .sell, .bondRedemption, .split].contains(type) }
    public var usesTax: Bool { [.dividend, .coupon, .interest].contains(type) }
    public var usesSplit: Bool { type == .split }
    public var usesCounter: Bool { type == .fxConversion }
    public var usesAccruedInterest: Bool {
        usesQuantityAndPrice && instruments.first { $0.id == instrumentID }?.instrument.kind.isBond == true
    }

    private func parse(_ text: String) -> Decimal?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .some(nil) }
        guard let value = DecimalSupport.parse(trimmed, locale: locale) else { return nil } // invalid
        return .some(value)
    }

    /// Builds the transaction or reports the first invalid field.
    public func makeTransaction() -> Result<Transaction, Message> {
        var parsed: [String: Decimal?] = [:]
        for (name, text) in [("quantity", quantityText), ("price", priceText), ("amount", amountText), ("fees", feesText),
                             ("tax", taxText), ("accrued", accruedInterestText), ("fx", fxRateText), ("counter", counterAmountText)] {
            guard let value = parse(text) else { return .failure(Message("transaction.error.invalidNumber", [.key("transaction.field.\(name)")])) }
            parsed[name] = value
        }
        let tradeDate = LocalDate(date, timeZone: .current)
        guard tradeDate <= app.environment.clock.today() else { return .failure(Message("transaction.error.futureDate")) }
        var transaction = Transaction(
            id: editing?.id ?? TransactionID(), portfolioID: portfolio.id, type: type, instrumentID: usesInstrument ? instrumentID : nil,
            listingID: nil, tradeDate: tradeDate,
            quantity: usesQuantityAndPrice ? (parsed["quantity"] ?? nil) : nil, price: usesQuantityAndPrice ? (parsed["price"] ?? nil) : nil,
            amount: usesAmount ? (parsed["amount"] ?? nil) : nil, currency: currency, fees: (parsed["fees"] ?? nil) ?? 0,
            feeCurrency: feeInBaseCurrency && currency != baseCurrency ? baseCurrency : nil,
            taxWithheld: usesTax ? ((parsed["tax"] ?? nil) ?? 0) : 0,
            accruedInterest: usesAccruedInterest ? (parsed["accrued"] ?? nil) : nil,
            fxRateToBase: currency == baseCurrency ? nil : (parsed["fx"] ?? nil),
            counterCurrency: usesCounter ? counterCurrency : nil, counterAmount: usesCounter ? (parsed["counter"] ?? nil) : nil,
            splitNumerator: usesSplit ? Int(splitNumeratorText) : nil, splitDenominator: usesSplit ? Int(splitDenominatorText) : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            source: isVirtual ? .simulator : .manual, createdAt: editing?.createdAt ?? app.environment.clock.now())
        if let entry = instruments.first(where: { $0.id == instrumentID }), let listing = entry.listing,
           listing.tradingCurrency == currency { transaction.listingID = listing.id }
        do {
            try TransactionValidator.validate(transaction, baseCurrency: baseCurrency)
        } catch let error as TransactionValidationError {
            return .failure(Self.message(for: error))
        } catch {
            return .failure(Message("error.generic"))
        }
        return .success(transaction)
    }

    public func save() async {
        guard let services = app.services else { return }
        switch makeTransaction() {
        case .failure(let message):
            error = message
        case .success(let transaction):
            do {
                if editing != nil { try await services.portfolios.update(transaction) } else { try await services.portfolios.add([transaction]) }
                error = nil
                saved = true
            } catch PortfolioServiceError.ledger(.insufficientQuantity(_, let available, _)) {
                error = Message("transaction.error.insufficientQuantity", [.decimal(available, fractionDigits: 4)])
            } catch PortfolioServiceError.ledger(.noPosition) {
                error = Message("transaction.error.noPosition")
            } catch {
                self.error = Message("transaction.error.saveFailed")
            }
        }
    }

    static func message(for error: TransactionValidationError) -> Message {
        switch error {
        case .missingField(let field): return Message("transaction.error.missingField", [.key("transaction.field.\(field)")])
        case .nonPositive(let field): return Message("transaction.error.nonPositive", [.key("transaction.field.\(field)")])
        case .negative(let field): return Message("transaction.error.negative", [.key("transaction.field.\(field)")])
        case .invalidSplitRatio: return Message("transaction.error.invalidSplit")
        case .sameCurrencyConversion: return Message("transaction.error.sameCurrency")
        case .unsupportedFeeCurrency: return Message("transaction.error.feeCurrency")
        case .notesTooLong: return Message("transaction.error.notesTooLong")
        case .taxExceedsIncome: return Message("transaction.error.taxExceedsIncome")
        }
    }

    private func populate(from t: Transaction) {
        type = t.type
        date = t.tradeDate.startOfDay(in: .current)
        instrumentID = t.instrumentID
        currency = t.currency
        func text(_ value: Decimal?) -> String { value.map { $0.formatted(.number.locale(locale).grouping(.never)) } ?? "" }
        quantityText = text(t.quantity)
        priceText = text(t.price)
        amountText = text(t.amount)
        feesText = t.fees == 0 ? "" : text(t.fees)
        feeInBaseCurrency = t.feeCurrency != nil && t.feeCurrency != t.currency
        taxText = t.taxWithheld == 0 ? "" : text(t.taxWithheld)
        accruedInterestText = text(t.accruedInterest)
        fxRateText = text(t.fxRateToBase)
        counterCurrency = t.counterCurrency ?? .eur
        counterAmountText = text(t.counterAmount)
        splitNumeratorText = t.splitNumerator.map(String.init) ?? ""
        splitDenominatorText = t.splitDenominator.map(String.init) ?? ""
        notes = t.notes ?? ""
    }
}

/// CSV import with a preview step (nothing is written until the user confirms).
@MainActor
@Observable
public final class CSVImportViewModel {
    public private(set) var parsed: TransactionCSV.ParseResult?
    public private(set) var outcome: ImportOutcome?
    public private(set) var error: Message?
    private let app: AppModel
    private let portfolioID: PortfolioID

    public init(app: AppModel, portfolioID: PortfolioID) {
        self.app = app
        self.portfolioID = portfolioID
    }

    public func preview(_ data: Data) {
        outcome = nil
        error = nil
        parsed = TransactionCSV.parse(data)
    }

    public var canImport: Bool { !(parsed?.rows.isEmpty ?? true) && outcome == nil }

    public func confirmImport() async {
        guard let services = app.services, let rows = parsed?.rows, !rows.isEmpty else { return }
        do {
            outcome = try await services.portfolios.importRows(rows, into: portfolioID, now: app.environment.clock.now())
            error = nil
        } catch PortfolioServiceError.ledger(.insufficientQuantity) {
            error = Message("import.error.oversell")
        } catch {
            self.error = Message("import.error.failed")
        }
    }
}
