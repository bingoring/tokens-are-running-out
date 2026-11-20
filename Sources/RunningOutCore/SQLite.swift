import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLite error \(code): \(message)" }

    /// The file is not a usable database and should be rebuilt.
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    static func int(_ value: Int) -> SQLValue { .int(Int64(value)) }
    static func optionalText(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optionalDouble(_ value: Double?) -> SQLValue { value.map(SQLValue.double) ?? .null }
}

/// A thin wrapper over the SQLite3 C API that ships with macOS. Not thread-safe; use from one thread.
///
/// Statements are cached, and every helper resets its statement when it returns. A statement left
/// mid-step keeps a read transaction open, which pins the WAL and makes later writes fail with
/// "database is locked" once another connection has written.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: Statement] = [:]

    /// `noFollow`: refuse a path with any symbolic link in it. The index path is resolved to its physical path
    /// before it is checked, so a link that appears there afterwards is not followed.
    init(path: String, noFollow: Bool = false) throws {
        let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | (noFollow ? SQLITE_OPEN_NOFOLLOW : 0)
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: code, message: message)
        }
        // Another process (the CLI next to the app) may hold the write lock briefly.
        sqlite3_busy_timeout(handle, 5_000)
    }

    /// Opens a file read-only without taking locks or creating side files (`immutable=1`), to look at a file
    /// that may belong to another app.
    init(immutableSnapshotOf url: URL) throws {
        let uri = url.standardizedFileURL.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(uri, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: code, message: message)
        }
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(code) }
    }

    /// Runs a statement to completion.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepared(sql)
        defer { statement.reset() }
        try statement.bind(values)
        while try statement.step() {}
    }

    /// Reads the first row, if any.
    func queryRow<T>(_ sql: String, _ values: [SQLValue] = [], _ read: (Statement) throws -> T) throws -> T? {
        let statement = try prepared(sql)
        defer { statement.reset() }
        try statement.bind(values)
        return try statement.step() ? read(statement) : nil
    }

    /// Calls `each` for every row. Do not run the same SQL again from inside `each`.
    func query(_ sql: String, _ values: [SQLValue] = [], _ each: (Statement) throws -> Void) throws {
        let statement = try prepared(sql)
        defer { statement.reset() }
        try statement.bind(values)
        while try statement.step() { try each(statement) }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            for statement in statements.values { statement.reset() }
            try execute("COMMIT")
            return result
        } catch {
            for statement in statements.values { statement.reset() }
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    private func prepared(_ sql: String) throws -> Statement {
        if let cached = statements[sql] { return cached }
        var raw: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &raw, nil)
        guard code == SQLITE_OK, let raw else { throw error(code) }
        let statement = Statement(raw: raw, database: self)
        statements[sql] = statement
        return statement
    }
}

final class Statement {
    private let raw: OpaquePointer
    private unowned let database: SQLiteDatabase
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(raw: OpaquePointer, database: SQLiteDatabase) {
        self.raw = raw
        self.database = database
    }

    deinit { sqlite3_finalize(raw) }

    fileprivate func reset() {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
    }

    fileprivate func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let v): code = sqlite3_bind_int64(raw, index, v)
            case .double(let v): code = sqlite3_bind_double(raw, index, v)
            case .text(let v): code = sqlite3_bind_text(raw, index, v, -1, Statement.transient)
            case .null: code = sqlite3_bind_null(raw, index)
            }
            guard code == SQLITE_OK else { throw database.error(code) }
        }
    }

    /// Steps once. Returns true when a row is available.
    fileprivate func step() throws -> Bool {
        let code = sqlite3_step(raw)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.error(code)
        }
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(raw, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(raw, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
}
