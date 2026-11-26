import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLiteError: Error, Equatable, Sendable {
    case openFailed(String)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case constraintViolation(String)
    case serializationFailed
    case deserializationFailed
    case integrityCheckFailed([String])
    case missingColumn(String)
    case typeMismatch(column: String)
}

/// SQLITE_TRANSIENT tells SQLite to copy bound buffers immediately.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal, synchronous SQLite connection to an **in-memory** database.
///
/// Not thread-safe by design: each instance is owned by exactly one `DatabaseStore` actor, which
/// serialises all access (docs/ARCHITECTURE.md §3.2). Persistence to disk happens via `serialize()`
/// + encryption (ADR-003).
public final class SQLiteDatabase {
    let handle: OpaquePointer

    /// Opens an empty in-memory database.
    public init() throws {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(":memory:", &pointer, flags, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw SQLiteError.openFailed("sqlite3_open_v2 failed")
        }
        handle = pointer
        try configure()
    }

    /// Loads a database image produced by `serialize()`.
    public convenience init(image: Data) throws {
        try self.init()
        let size = Int64(image.count)
        guard size > 0, let buffer = sqlite3_malloc64(UInt64(size)) else { throw SQLiteError.deserializationFailed }
        image.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer, base, image.count) }
        }
        // FREEONCLOSE: SQLite owns the buffer. RESIZEABLE: the database can grow after loading.
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let result = sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self), size, size, flags)
        guard result == SQLITE_OK else { throw SQLiteError.deserializationFailed }
        try configure()
        // A random file that happens to decrypt cannot exist (AES-GCM), but verify the image anyway.
        let check = try integrityCheck()
        guard check.isEmpty else { throw SQLiteError.integrityCheckFailed(check) }
    }

    deinit { sqlite3_close_v2(handle) }

    private func configure() throws {
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA recursive_triggers = ON;")
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Executes one or more SQL statements without parameters.
    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw Self.error(code: result, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(code: result, message: lastErrorMessage)
        }
        return SQLiteStatement(statement: statement, database: self)
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        try statement.runToCompletion()
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        return try statement.allRows()
    }

    public func queryOne(_ sql: String, _ bindings: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, bindings).first
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64? {
        guard let row = try queryOne(sql, bindings), let first = row.values.first else { return nil }
        if case .integer(let value) = first { return value }
        return nil
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version;")) ?? 0) }
    }

    public func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version);") }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`; rolls back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;") // Rollback failure is secondary to the original error.
            throw error
        }
    }

    /// Returns a byte image of the whole database (`sqlite3_serialize`).
    public func serialize() throws -> Data {
        // An empty in-memory database has no pages and serialises to NULL; writing the header
        // (user_version) materialises page 1 so every database has a valid image.
        if (try scalarInt("PRAGMA page_count;")) == 0 { try setUserVersion(userVersion) }
        var size: Int64 = 0
        guard let pointer = sqlite3_serialize(handle, "main", &size, 0) else { throw SQLiteError.serializationFailed }
        defer { sqlite3_free(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }

    /// `PRAGMA integrity_check` + `PRAGMA foreign_key_check`. Empty array = healthy.
    public func integrityCheck() throws -> [String] {
        var problems: [String] = []
        for row in try query("PRAGMA integrity_check;") {
            if let text = row.values.first?.textValue, text != "ok" { problems.append(text) }
        }
        for row in try query("PRAGMA foreign_key_check;") {
            problems.append("foreign key violation in \(row.values.first?.textValue ?? "?")")
        }
        return problems
    }

    static func error(code: Int32, message: String) -> SQLiteError {
        (code & 0xFF) == SQLITE_CONSTRAINT ? .constraintViolation(message) : .stepFailed(code: code, message: message)
    }
}

/// A prepared statement. Finalised on deinit.
public final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    public func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let v): result = sqlite3_bind_int64(statement, index, v)
            case .real(let v): result = sqlite3_bind_double(statement, index, v)
            case .text(let v): result = sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v):
                result = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(v.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.prepareFailed(code: result, message: database.lastErrorMessage)
            }
        }
    }

    public func runToCompletion() throws {
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result != SQLITE_ROW { throw SQLiteDatabase.error(code: result, message: database.lastErrorMessage) }
        }
    }

    public func allRows() throws -> [SQLRow] {
        var rows: [SQLRow] = []
        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        for i in 0..<columnCount { names.append(String(cString: sqlite3_column_name(statement, i))) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw SQLiteDatabase.error(code: result, message: database.lastErrorMessage) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(columnCount))
            for i in 0..<columnCount { values.append(columnValue(i)) }
            rows.append(SQLRow(names: names, values: values))
        }
        return rows
    }

    private func columnValue(_ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default: return .null
        }
    }
}
