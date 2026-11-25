import Foundation
import InvestiQCore

public enum SQLValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var textValue: String? { if case .text(let v) = self { return v }; return nil }
}

/// Conversions used by repositories. Decimals are stored as canonical TEXT (docs/DATABASE_SCHEMA.md).
public extension SQLValue {
    static func of(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func of(_ value: Int?) -> SQLValue { value.map { .integer(Int64($0)) } ?? .null }
    static func of(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    static func of(_ value: Double?) -> SQLValue { value.flatMap { $0.isFinite ? .real($0) : nil } ?? .null }
    static func of(_ value: Decimal?) -> SQLValue { value.map { .text($0.canonicalString) } ?? .null }
    static func of(_ value: LocalDate?) -> SQLValue { value.map { .text($0.iso) } ?? .null }
    static func of(_ value: Date?) -> SQLValue { value.map { .text(InstantCoding.string(from: $0)) } ?? .null }
    static func of(_ value: CurrencyCode?) -> SQLValue { value.map { .text($0.rawValue) } ?? .null }
    static func of<ID: UUIDIdentifier>(_ value: ID?) -> SQLValue { value.map { .text($0.string) } ?? .null }
    static func of<E: RawRepresentable>(_ value: E?) -> SQLValue where E.RawValue == String { value.map { .text($0.rawValue) } ?? .null }
    static func json<T: Encodable>(_ value: T) throws -> SQLValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return .text(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

/// A result row with typed accessors that fail loudly on type errors (no silent defaults).
public struct SQLRow: Sendable {
    let names: [String]
    public let values: [SQLValue]

    init(names: [String], values: [SQLValue]) {
        self.names = names
        self.values = values
    }

    public subscript(_ column: String) -> SQLValue {
        guard let index = names.firstIndex(of: column) else { return .null }
        return values[index]
    }

    public func string(_ column: String) throws -> String {
        guard case .text(let value) = self[column] else { throw SQLiteError.typeMismatch(column: column) }
        return value
    }

    public func optionalString(_ column: String) -> String? { self[column].textValue }

    public func int(_ column: String) throws -> Int {
        guard case .integer(let value) = self[column] else { throw SQLiteError.typeMismatch(column: column) }
        return Int(value)
    }

    public func optionalInt(_ column: String) -> Int? {
        if case .integer(let value) = self[column] { return Int(value) }
        return nil
    }

    public func bool(_ column: String) throws -> Bool { try int(column) != 0 }

    public func optionalDouble(_ column: String) -> Double? {
        switch self[column] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public func decimal(_ column: String) throws -> Decimal {
        guard let value = try optionalDecimal(column) else { throw SQLiteError.typeMismatch(column: column) }
        return value
    }

    public func optionalDecimal(_ column: String) throws -> Decimal? {
        guard case .text(let text) = self[column] else {
            if case .null = self[column] { return nil }
            throw SQLiteError.typeMismatch(column: column)
        }
        guard let value = DecimalSupport.parse(text) else { throw SQLiteError.typeMismatch(column: column) }
        return value
    }

    public func localDate(_ column: String) throws -> LocalDate {
        guard let value = try optionalLocalDate(column) else { throw SQLiteError.typeMismatch(column: column) }
        return value
    }

    public func optionalLocalDate(_ column: String) throws -> LocalDate? {
        guard let text = self[column].textValue else { return nil }
        guard let date = LocalDate(iso: text) else { throw SQLiteError.typeMismatch(column: column) }
        return date
    }

    public func instant(_ column: String) throws -> Date {
        guard let text = self[column].textValue, let date = InstantCoding.date(from: text) else {
            throw SQLiteError.typeMismatch(column: column)
        }
        return date
    }

    public func optionalInstant(_ column: String) -> Date? {
        self[column].textValue.flatMap(InstantCoding.date(from:))
    }

    public func currency(_ column: String) throws -> CurrencyCode {
        guard let code = CurrencyCode(rawValue: try string(column)) else { throw SQLiteError.typeMismatch(column: column) }
        return code
    }

    public func optionalCurrency(_ column: String) -> CurrencyCode? { self[column].textValue.flatMap(CurrencyCode.init(rawValue:)) }

    public func id<ID: UUIDIdentifier>(_ column: String, as type: ID.Type = ID.self) throws -> ID {
        guard let id = ID(string: try string(column)) else { throw SQLiteError.typeMismatch(column: column) }
        return id
    }

    public func optionalID<ID: UUIDIdentifier>(_ column: String, as type: ID.Type = ID.self) -> ID? {
        self[column].textValue.flatMap(ID.init(string:))
    }

    public func enumValue<E: RawRepresentable>(_ column: String, as type: E.Type = E.self) throws -> E where E.RawValue == String {
        guard let value = E(rawValue: try string(column)) else { throw SQLiteError.typeMismatch(column: column) }
        return value
    }

    public func optionalEnum<E: RawRepresentable>(_ column: String, as type: E.Type = E.self) -> E? where E.RawValue == String {
        self[column].textValue.flatMap(E.init(rawValue:))
    }

    public func blob(_ column: String) throws -> Data {
        guard case .blob(let data) = self[column] else { throw SQLiteError.typeMismatch(column: column) }
        return data
    }

    public func json<T: Decodable>(_ column: String, as type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(try string(column).utf8))
    }
}
