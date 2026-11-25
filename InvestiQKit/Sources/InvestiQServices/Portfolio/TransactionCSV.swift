import Foundation
import InvestiQCore
import InvestiQSecurity

/// InvestiQ CSV format for transactions (import and export).
/// Columns are matched by header name; unknown columns are ignored.
public enum TransactionCSV {
    public static let columns = ["date", "type", "isin", "ticker", "mic", "name", "instrument_kind", "quantity", "price", "amount",
                                 "currency", "fees", "fee_currency", "tax_withheld", "accrued_interest", "fx_rate_to_base",
                                 "counter_currency", "counter_amount", "split_numerator", "split_denominator", "notes", "external_ref"]
    public static let maximumImportBytes = 5 * 1024 * 1024
    public static let maximumRows = 20_000

    // MARK: Export

    /// Exports with formula-injection protection (CSVSanitizer) and canonical decimals.
    public static func export(_ transactions: [Transaction], instruments: [InstrumentID: Instrument], listings: [InstrumentID: Listing]) -> String {
        var lines = [CSVSanitizer.row(columns)]
        for t in PortfolioLedger.ordered(transactions) {
            let instrument = t.instrumentID.flatMap { instruments[$0] }
            let listing = t.instrumentID.flatMap { listings[$0] }
            func d(_ value: Decimal?) -> String { value?.canonicalString ?? "" }
            lines.append(CSVSanitizer.row([
                t.tradeDate.iso, t.type.rawValue, instrument?.isin?.rawValue ?? "", listing?.ticker.rawValue ?? "",
                listing?.mic?.rawValue ?? "", instrument?.name ?? "", instrument?.kind.rawValue ?? "", d(t.quantity), d(t.price),
                d(t.amount), t.currency.rawValue, d(t.fees), t.feeCurrency?.rawValue ?? "", d(t.taxWithheld), d(t.accruedInterest),
                d(t.fxRateToBase), t.counterCurrency?.rawValue ?? "", d(t.counterAmount), t.splitNumerator.map(String.init) ?? "",
                t.splitDenominator.map(String.init) ?? "", t.notes ?? "", t.externalRef ?? t.id.string,
            ]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Import

    public struct ParsedRow: Sendable, Hashable {
        public var line: Int
        public var date: LocalDate
        public var type: TransactionType
        public var isin: ISIN?
        public var ticker: Ticker?
        public var mic: MIC?
        public var name: String?
        public var kind: InstrumentKind?
        public var quantity: Decimal?
        public var price: Decimal?
        public var amount: Decimal?
        public var currency: CurrencyCode
        public var fees: Decimal
        public var feeCurrency: CurrencyCode?
        public var taxWithheld: Decimal
        public var accruedInterest: Decimal?
        public var fxRateToBase: Decimal?
        public var counterCurrency: CurrencyCode?
        public var counterAmount: Decimal?
        public var splitNumerator: Int?
        public var splitDenominator: Int?
        public var notes: String?
        /// From the file, or a content hash so that re-importing the same file never duplicates rows.
        public var externalRef: String
        public var needsInstrument: Bool { type.requiresInstrument }
    }

    public struct RowError: Error, Sendable, Hashable {
        public var line: Int
        public var message: Message
    }

    public struct ParseResult: Sendable {
        public var rows: [ParsedRow]
        public var errors: [RowError]
    }

    /// Parses and validates a CSV file without touching any data (preview step).
    public static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maximumImportBytes else {
            return ParseResult(rows: [], errors: [RowError(line: 0, message: Message("import.error.fileTooLarge"))])
        }
        guard var text = String(data: data, encoding: .utf8) else {
            return ParseResult(rows: [], errors: [RowError(line: 0, message: Message("import.error.notUTF8"))])
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        // Spreadsheet apps in cs/ru locales export with ";" and decimal commas.
        let delimiter: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        let table: CSVTable
        do {
            table = CSVTable(rows: try CSVParser(delimiter: delimiter, maximumRows: maximumRows + 1).parse(text))
        } catch {
            return ParseResult(rows: [], errors: [RowError(line: 0, message: Message("import.error.malformed"))])
        }
        guard table.index(of: "date") != nil, table.index(of: "type") != nil, table.index(of: "currency") != nil else {
            return ParseResult(rows: [], errors: [RowError(line: 1, message: Message("import.error.missingColumns",
                                                                                         [.text("date, type, currency")]))])
        }
        var rows: [ParsedRow] = []
        var errors: [RowError] = []
        for (index, cells) in table.rows.enumerated() {
            let line = index + 2
            do {
                rows.append(try parseRow(cells, table: table, line: line, decimalComma: delimiter == ";"))
            } catch let error as RowError {
                errors.append(error)
            } catch {
                errors.append(RowError(line: line, message: Message("import.error.invalidRow")))
            }
        }
        return ParseResult(rows: rows, errors: errors)
    }

    static func parseRow(_ cells: [String], table: CSVTable, line: Int, decimalComma: Bool) throws -> ParsedRow {
        func value(_ column: String) -> String? { table.value(cells, column) }
        func fail(_ key: String, _ column: String) -> RowError { RowError(line: line, message: Message(key, [.text(column)])) }
        func decimal(_ column: String) throws -> Decimal? {
            guard var text = value(column) else { return nil }
            if decimalComma { text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            text = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            guard let number = DecimalSupport.parse(text) else { throw fail("import.error.invalidNumber", column) }
            return number
        }
        func currency(_ column: String) throws -> CurrencyCode? {
            guard let text = value(column) else { return nil }
            guard let code = CurrencyCode(rawValue: text) else { throw fail("import.error.invalidCurrency", column) }
            return code
        }
        guard let dateText = value("date"), let date = parseDate(dateText) else { throw fail("import.error.invalidDate", "date") }
        guard let typeText = value("type"), let type = TransactionType(rawValue: typeText) else { throw fail("import.error.invalidType", "type") }
        guard let currencyCode = try currency("currency") else { throw fail("import.error.invalidCurrency", "currency") }
        let isinText = value("isin")
        let isin = isinText.flatMap(ISIN.init(rawValue:))
        if isinText != nil && isin == nil { throw fail("import.error.invalidISIN", "isin") }
        var row = ParsedRow(line: line, date: date, type: type, isin: isin, ticker: value("ticker").flatMap(Ticker.init(rawValue:)),
                            mic: value("mic").flatMap(MIC.init(rawValue:)), name: value("name"),
                            kind: value("instrument_kind").flatMap(InstrumentKind.init(rawValue:)), quantity: try decimal("quantity"),
                            price: try decimal("price"), amount: try decimal("amount"), currency: currencyCode, fees: try decimal("fees") ?? 0,
                            feeCurrency: try currency("fee_currency"), taxWithheld: try decimal("tax_withheld") ?? 0,
                            accruedInterest: try decimal("accrued_interest"), fxRateToBase: try decimal("fx_rate_to_base"),
                            counterCurrency: try currency("counter_currency"), counterAmount: try decimal("counter_amount"),
                            splitNumerator: value("split_numerator").flatMap { Int($0) }, splitDenominator: value("split_denominator").flatMap { Int($0) },
                            notes: value("notes").map { String($0.prefix(TransactionValidator.maximumNotesLength)) }, externalRef: "")
        if row.needsInstrument && row.isin == nil && row.ticker == nil { throw fail("import.error.missingInstrument", "isin/ticker") }
        row.externalRef = value("external_ref") ?? contentHash(cells)
        return row
    }

    /// Accepts ISO dates and the common European formats dd.mm.yyyy and dd/mm/yyyy.
    static func parseDate(_ text: String) -> LocalDate? {
        if let iso = LocalDate(iso: text), text.count == 10 { return iso }
        for separator in [".", "/"] {
            let parts = text.split(separator: Character(separator)).map(String.init)
            if parts.count == 3, let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]), parts[2].count == 4 {
                return LocalDate(year: y, month: m, day: d)
            }
        }
        return nil
    }

    static func contentHash(_ cells: [String]) -> String {
        "csv-" + CryptoBox.sha256Hex(Data(cells.joined(separator: "\u{1F}").utf8)).prefix(32)
    }
}
