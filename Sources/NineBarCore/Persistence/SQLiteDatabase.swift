import Foundation
import SQLite3

public enum PersistenceError: Error, Equatable, Sendable {
    case database(String)
    case invalidColumn(String)
    case invalidTimeframe(Int)
    case invalidSignalDirection(String)
}

enum SQLiteValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func integer(_ index: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw PersistenceError.invalidColumn("Expected integer at column \(index)")
        }
        return sqlite3_column_int64(statement, index)
    }

    func double(_ index: Int32) throws -> Double {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else {
            throw PersistenceError.invalidColumn("Expected number at column \(index)")
        }
        return sqlite3_column_double(statement, index)
    }

    func optionalDouble(_ index: Int32) throws -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try double(index)
    }

    func optionalInteger(_ index: Int32) throws -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try integer(index)
    }

    func text(_ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else {
            throw PersistenceError.invalidColumn("Expected text at column \(index)")
        }
        return String(cString: value)
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var openedHandle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &openedHandle, flags, nil)
        guard result == SQLITE_OK, let openedHandle else {
            let message = openedHandle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open SQLite database"
            if let openedHandle {
                sqlite3_close_v2(openedHandle)
            }
            throw PersistenceError.database(message)
        }

        handle = openedHandle
        guard sqlite3_busy_timeout(handle, 3_000) == SQLITE_OK else {
            throw databaseError()
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw databaseError()
            }
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try map(SQLiteRow(statement: statement)))
            case SQLITE_DONE:
                return results
            default:
                throw databaseError()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw databaseError()
        }
        guard let statement else {
            throw PersistenceError.database("SQLite produced no prepared statement")
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
            throw PersistenceError.database("SQLite binding count does not match statement")
        }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, transientDestructor)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    private func databaseError() -> PersistenceError {
        PersistenceError.database(String(cString: sqlite3_errmsg(handle)))
    }
}
