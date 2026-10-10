import Foundation
import SQLite3
import Darwin

// Errors deliberately contain neither SQLite diagnostics nor producer-controlled values.
enum ProjectUsageIndexStoreError: Error, Equatable {
    case database, schema, invalidMetadata, staleGeneration, invalidCheckpoint, staleRevision, maintenancePending
}

enum ProjectIndexValue {
    case int(Int64), real(Double), text(String), blob(Data), null
}

final class ProjectIndexStatement {
    let handle: OpaquePointer
    init(_ db: OpaquePointer, _ sql: String, _ values: [ProjectIndexValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ProjectUsageIndexStoreError.database
        }
        handle = statement
        do {
            guard sqlite3_bind_parameter_count(handle) == Int32(values.count) else {
                throw ProjectUsageIndexStoreError.database
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                let status: Int32
                switch value {
                case .int(let value): status = sqlite3_bind_int64(handle, index, value)
                case .real(let value): status = sqlite3_bind_double(handle, index, value)
                case .text(let value):
                    guard value.utf8.count <= 8192 else { throw ProjectUsageIndexStoreError.invalidMetadata }
                    status = value.withCString { sqlite3_bind_text(handle, index, $0, Int32(value.utf8.count), transient) }
                case .blob(let value):
                    guard value.count <= 32 else { throw ProjectUsageIndexStoreError.invalidMetadata }
                    status = value.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(value.count), transient) }
                case .null: status = sqlite3_bind_null(handle, index)
                }
                guard status == SQLITE_OK else { throw ProjectUsageIndexStoreError.database }
            }
        } catch { sqlite3_finalize(statement); throw error }
    }
    deinit { sqlite3_finalize(handle) }
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ProjectUsageIndexStoreError.database
        }
    }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func real(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(handle, i) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(handle, i))), as: UTF8.self)
    }
    func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(handle, i)))
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    func totals(_ i: Int32) -> ProjectUsageTotals {
        .init(responses: Int(int(i)), inputTokens: Int(int(i+1)), outputTokens: Int(int(i+2)),
              cacheReadTokens: Int(int(i+3)), cacheWriteTokens: Int(int(i+4)), totalTokens: Int(int(i+5)))
    }
}

final class ProjectIndexDatabase {
    let handle: OpaquePointer
    init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            throw ProjectUsageIndexStoreError.database
        }
        handle = db
        sqlite3_busy_timeout(db, 250)
        sqlite3_progress_handler(db, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
    }
    deinit { sqlite3_close_v2(handle) }
    func query(_ sql: String, _ values: [ProjectIndexValue] = []) throws -> ProjectIndexStatement {
        try .init(handle, sql, values)
    }
    func run(_ sql: String, _ values: [ProjectIndexValue] = []) throws {
        let q = try query(sql, values)
        while try q.step() {} // Only DDL, PRAGMA or bounded writes use run.
    }
    func scalar(_ sql: String, _ values: [ProjectIndexValue] = []) throws -> Int64 {
        let q = try query(sql, values)
        return try q.step() ? q.int(0) : 0
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let result = try body(); try run("COMMIT"); return result }
        catch { try? run("ROLLBACK"); throw error }
    }
}

extension ProjectUsageTotals {
    var indexValues: [ProjectIndexValue] {
        [responses, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens].map { .int(Int64($0)) }
    }
}

extension ProjectUsageFileSignature {
    var encoded: String {
        [Int64(bitPattern: device), Int64(bitPattern: inode), size, modifiedSeconds, modifiedNanos,
         changedSeconds, changedNanos].map(String.init).joined(separator: ",")
    }
    init(encoded: String) throws {
        let values = encoded.split(separator: ",").compactMap { Int64($0) }
        guard values.count == 7 else { throw ProjectUsageIndexStoreError.schema }
        self.init(device: UInt64(bitPattern: values[0]), inode: UInt64(bitPattern: values[1]), size: values[2],
                  modifiedSeconds: values[3], modifiedNanos: values[4], changedSeconds: values[5], changedNanos: values[6])
    }
    var valid: Bool { size >= 0 && (0..<1_000_000_000).contains(modifiedNanos) && (0..<1_000_000_000).contains(changedNanos) }
}
