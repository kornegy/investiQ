import Foundation

public enum CSVError: Error, Equatable, Sendable {
    case unterminatedQuote(line: Int)
    case tooManyRows(limit: Int)
    case fieldTooLong(line: Int)
    case notUTF8
}

/// RFC 4180 CSV parser with size limits (untrusted input — THREAT_MODEL T6/T12). All cells are
/// returned as plain strings; nothing is ever evaluated.
public struct CSVParser: Sendable {
    public var delimiter: Character
    public var maximumRows: Int
    public var maximumFieldLength: Int

    public init(delimiter: Character = ",", maximumRows: Int = 100_000, maximumFieldLength: Int = 10_000) {
        self.delimiter = delimiter
        self.maximumRows = maximumRows
        self.maximumFieldLength = maximumFieldLength
    }

    public func parse(_ data: Data) throws -> [[String]] {
        guard var text = String(data: data, encoding: .utf8) else { throw CSVError.notUTF8 }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() } // UTF-8 BOM written by spreadsheet apps
        return try parse(text)
    }

    public func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()

        func endField() throws {
            guard field.count <= maximumFieldLength else { throw CSVError.fieldTooLong(line: line) }
            row.append(field)
            field = ""
        }
        func endRow() throws {
            try endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            guard rows.count <= maximumRows else { throw CSVError.tooManyRows(limit: maximumRows) }
        }

        while let character = pending {
            pending = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() } else { inQuotes = false }
                } else {
                    if character == "\n" || character == "\r\n" { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: inQuotes = true
            case delimiter: try endField()
            case "\n", "\r\n", "\r":
                try endRow()
                line += 1
            default: field.append(character)
            }
        }
        if inQuotes { throw CSVError.unterminatedQuote(line: line) }
        if !field.isEmpty || !row.isEmpty { try endRow() }
        return rows
    }
}

/// Header-indexed access to CSV rows (columns located by name, not position).
public struct CSVTable: Sendable {
    public let header: [String]
    public let rows: [[String]]

    public init(rows: [[String]]) {
        header = rows.first?.map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        self.rows = Array(rows.dropFirst())
    }

    public func index(of column: String) -> Int? {
        header.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame }
    }

    public func value(_ row: [String], _ column: String) -> String? {
        guard let index = index(of: column), index < row.count else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
