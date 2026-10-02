import Foundation
import SQLite3

private enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
}

private final class UsageStatement {
    let handle: OpaquePointer

    init?(_ database: OpaquePointer?, _ sql: String) {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        handle = statement
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) -> Bool {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let number):
                result = sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                result = sqlite3_bind_double(handle, index, number)
            case .text(let text):
                guard text.utf8.count <= Int(Int32.max) else { return false }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                result = text.withCString {
                    sqlite3_bind_text(handle, index, $0, Int32(text.utf8.count), transient)
                }
            }
            guard result == SQLITE_OK else { return false }
        }
        return true
    }

    func run() -> Bool {
        var status = sqlite3_step(handle)
        while status == SQLITE_ROW { status = sqlite3_step(handle) }
        return status == SQLITE_DONE
    }

    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(handle, column) else { return "" }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func count(_ column: Int32) -> Int {
        let value = sqlite3_column_double(handle, column)
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(Int.max) ? Int.max : Int(value)
    }

    func totals(_ column: Int32) -> UsageTotals {
        UsageTotals(
            requests: count(column), failed: count(column + 1),
            inputTokens: count(column + 2), outputTokens: count(column + 3),
            totalTokens: count(column + 4))
    }
}

/// The actor is the only owner that executes statements; this holder also closes during teardown.
private final class UsageDatabase: @unchecked Sendable {
    let handle: OpaquePointer?

    init(url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacy = url.deletingLastPathComponent().appendingPathComponent("usage.json")
            if legacy != url,
                (try? legacy.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            {
                try? FileManager.default.removeItem(at: legacy)
            }
            if let opened = Self.open(url.path) {
                handle = opened
                return
            }
            Self.moveAside(url)
            handle = Self.open(url.path) ?? Self.open(":memory:")
        } else {
            handle = Self.open(":memory:")
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    static func execute(_ database: OpaquePointer?, _ sql: String, _ values: [SQLValue] = [])
        -> Bool
    {
        guard let statement = UsageStatement(database, sql), statement.bind(values) else {
            return false
        }
        return statement.run()
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 2000)
        guard valid(database),
            execute(database, "PRAGMA journal_mode = WAL"),
            execute(
                database,
                """
                CREATE TABLE IF NOT EXISTS buckets (
                    start INTEGER NOT NULL, auth_index TEXT NOT NULL, provider TEXT NOT NULL,
                    model TEXT NOT NULL, requests INTEGER NOT NULL, failed INTEGER NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL, total INTEGER NOT NULL,
                    PRIMARY KEY(start, auth_index, model)
                )
                """),
            execute(database, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value REAL)"),
            UsageStatement(
                database,
                "SELECT start, auth_index, provider, model, requests, failed, input, output, total FROM buckets LIMIT 0"
            ) != nil,
            execute(database, "PRAGMA user_version = 1")
        else {
            sqlite3_close_v2(database)
            return nil
        }
        return database
    }

    private static func valid(_ database: OpaquePointer) -> Bool {
        guard let check = UsageStatement(database, "PRAGMA quick_check(1)"),
            sqlite3_step(check.handle) == SQLITE_ROW
        else { return false }
        return check.text(0) == "ok"
    }

    private static func moveAside(_ url: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return }
        var destination = url.appendingPathExtension("corrupt")
        if files.fileExists(atPath: destination.path) {
            destination = destination.appendingPathExtension(UUID().uuidString)
        }
        guard (try? files.moveItem(at: url, to: destination)) != nil else { return }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if files.fileExists(atPath: sidecar.path) {
                try? files.moveItem(
                    at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
            }
        }
    }
}

/// Quarter-hour history containing routing identities and counters, never request payloads or keys.
public actor UsageStore {
    private let database: UsageDatabase
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    nonisolated let initialReports: [UsageRange: UsageReport]
    nonisolated let initialRequestsLastHour: Int

    public init(
        url: URL?, calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        initialRecords: [UsageRecord] = [], initialAccounts: [Account] = [],
        trackingSince: Date? = nil
    ) {
        let database = UsageDatabase(url: url)
        self.database = database
        self.calendar = calendar
        self.nowProvider = now
        let current = now()
        if let trackingSince, trackingSince.timeIntervalSince1970.isFinite {
            _ = UsageDatabase.execute(
                database.handle,
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('tracking_since', ?)",
                [.real(trackingSince.timeIntervalSince1970)])
        }
        if !initialRecords.isEmpty {
            Self.ingest(initialRecords, database: database.handle, now: current)
        }
        initialReports = Dictionary(
            uniqueKeysWithValues: UsageRange.allCases.map { range in
                (
                    range,
                    Self.report(
                        range, accounts: initialAccounts, now: current, calendar: calendar,
                        database: database.handle)
                )
            })
        initialRequestsLastHour = Self.requests(
            since: current.addingTimeInterval(-3600), database: database.handle)
    }

    public func ingest(_ records: [UsageRecord]) {
        Self.ingest(records, database: database.handle, now: nowProvider())
    }

    private static func ingest(_ records: [UsageRecord], database: OpaquePointer?, now: Date) {
        guard now.timeIntervalSince1970.isFinite,
            UsageDatabase.execute(database, "BEGIN IMMEDIATE")
        else { return }
        var committed = false
        defer {
            if !committed { _ = UsageDatabase.execute(database, "ROLLBACK") }
        }
        guard
            UsageDatabase.execute(
                database,
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('tracking_since', ?)",
                [.real(now.timeIntervalSince1970)]),
            let oldest = bucketStart(now.addingTimeInterval(-31 * 86400)),
            UsageDatabase.execute(
                database, "DELETE FROM buckets WHERE start < ?", [.integer(oldest)]),
            let upsert = UsageStatement(
                database,
                """
                INSERT INTO buckets(start, auth_index, provider, model, requests, failed, input, output, total)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(start, auth_index, model) DO UPDATE SET
                    provider = CASE WHEN excluded.provider = '' THEN provider ELSE excluded.provider END,
                    requests = CASE WHEN requests > 9223372036854775807 - excluded.requests THEN 9223372036854775807 ELSE requests + excluded.requests END,
                    failed = CASE WHEN failed > 9223372036854775807 - excluded.failed THEN 9223372036854775807 ELSE failed + excluded.failed END,
                    input = CASE WHEN input > 9223372036854775807 - excluded.input THEN 9223372036854775807 ELSE input + excluded.input END,
                    output = CASE WHEN output > 9223372036854775807 - excluded.output THEN 9223372036854775807 ELSE output + excluded.output END,
                    total = CASE WHEN total > 9223372036854775807 - excluded.total THEN 9223372036854775807 ELSE total + excluded.total END
                """)
        else { return }
        var models = storedModels(database)
        for record in records {
            let timestamp = record.timestamp ?? now
            guard timestamp.timeIntervalSince1970.isFinite,
                timestamp >= now.addingTimeInterval(-31 * 86400),
                let start = bucketStart(min(timestamp, now))
            else { continue }
            let rawModel =
                [record.model, record.alias].compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            var model = String(rawModel.prefix(64))
            if !models.contains(model), models.count >= (models.contains("other") ? 50 : 49) {
                model = "other"
            }
            models.insert(model)
            let input = nonnegative(record.tokens?.inputTokens)
            let output = nonnegative(record.tokens?.outputTokens)
            let supplied = nonnegative(record.tokens?.totalTokens)
            let total =
                supplied > 0
                ? supplied
                : addingCounts(
                    addingCounts(input, output), nonnegative(record.tokens?.reasoningTokens))
            let values: [SQLValue] = [
                .integer(start), .text(record.authIndex ?? ""), .text(record.provider ?? ""),
                .text(model),
                .integer(1), .integer(record.failed == true ? 1 : 0), .integer(Int64(input)),
                .integer(Int64(output)), .integer(Int64(total)),
            ]
            guard upsert.bind(values), upsert.run() else { return }
        }
        committed = UsageDatabase.execute(database, "COMMIT")
    }

    public func report(_ range: UsageRange, accounts: [Account], now: Date) -> UsageReport {
        Self.report(
            range, accounts: accounts, now: now, calendar: calendar, database: database.handle)
    }

    private static func report(
        _ range: UsageRange, accounts: [Account], now: Date,
        calendar: Calendar, database: OpaquePointer?
    ) -> UsageReport {
        let start = range.start(now: now, calendar: calendar)
        let trackingSince = trackingDate(database)
        guard let lower = bucketStart(start), let upper = bucketStart(now) else {
            return UsageReport(range: range, start: start, trackingSince: trackingSince)
        }
        let bounds: [SQLValue] = [.integer(lower), .integer(upper)]
        let accountQuery = UsageStatement(
            database,
            """
            SELECT auth_index, MAX(provider), SUM(CAST(requests AS REAL)), SUM(CAST(failed AS REAL)),
                SUM(CAST(input AS REAL)), SUM(CAST(output AS REAL)), SUM(CAST(total AS REAL))
            FROM buckets WHERE start >= ? AND start <= ? GROUP BY auth_index
            """)
        var byAccount: [AccountUsage] = []
        if let query = accountQuery, query.bind(bounds) {
            while sqlite3_step(query.handle) == SQLITE_ROW {
                let index = query.text(0)
                let known = accounts.first { $0.authIndex == index && !index.isEmpty }
                let provider = known?.provider ?? Provider(raw: query.text(1))
                let label =
                    known?.label
                    ?? (index.isEmpty ? "Unattributed" : provider.displayName + " API key")
                byAccount.append(
                    AccountUsage(
                        authIndex: index.isEmpty ? nil : index,
                        provider: provider, label: label, totals: query.totals(2)))
            }
        }
        byAccount.sort {
            if $0.totals.totalTokens != $1.totals.totalTokens {
                return $0.totals.totalTokens > $1.totals.totalTokens
            }
            if $0.totals.requests != $1.totals.requests {
                return $0.totals.requests > $1.totals.requests
            }
            return $0.label == $1.label ? $0.id < $1.id : $0.label < $1.label
        }
        let modelQuery = UsageStatement(
            database,
            """
            SELECT model, SUM(CAST(requests AS REAL)), SUM(CAST(failed AS REAL)),
                SUM(CAST(input AS REAL)), SUM(CAST(output AS REAL)), SUM(CAST(total AS REAL))
            FROM buckets WHERE start >= ? AND start <= ? GROUP BY model
            """)
        var byModel: [ModelUsage] = []
        if let query = modelQuery, query.bind(bounds) {
            while sqlite3_step(query.handle) == SQLITE_ROW {
                let counts = query.totals(1)
                byModel.append(
                    ModelUsage(
                        model: query.text(0), requests: counts.requests, failed: counts.failed,
                        inputTokens: counts.inputTokens, outputTokens: counts.outputTokens,
                        totalTokens: counts.totalTokens))
            }
        }
        byModel.sort {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.model < $1.model
        }
        let totals = byModel.reduce(UsageTotals.zero) { result, model in
            UsageTotals(
                requests: addingCounts(result.requests, model.requests),
                failed: addingCounts(result.failed, model.failed),
                inputTokens: addingCounts(result.inputTokens, model.inputTokens),
                outputTokens: addingCounts(result.outputTokens, model.outputTokens),
                totalTokens: addingCounts(result.totalTokens, model.totalTokens))
        }
        return UsageReport(
            range: range, start: start, totals: totals, byAccount: byAccount, byModel: byModel,
            trackingSince: trackingSince)
    }

    /// Counts include the quarter-hour bucket containing the requested boundary.
    public func requests(since: Date) -> Int {
        Self.requests(since: since, database: database.handle)
    }

    private static func requests(since: Date, database: OpaquePointer?) -> Int {
        guard let start = bucketStart(since),
            let query = UsageStatement(
                database, "SELECT SUM(CAST(requests AS REAL)) FROM buckets WHERE start >= ?"),
            query.bind([.integer(start)]), sqlite3_step(query.handle) == SQLITE_ROW
        else { return 0 }
        return query.count(0)
    }

    public func reset() {
        guard UsageDatabase.execute(database.handle, "BEGIN IMMEDIATE") else { return }
        if UsageDatabase.execute(database.handle, "DELETE FROM buckets"),
            UsageDatabase.execute(database.handle, "DELETE FROM meta"),
            UsageDatabase.execute(database.handle, "COMMIT")
        {
            return
        }
        _ = UsageDatabase.execute(database.handle, "ROLLBACK")
    }

    private static func bucketStart(_ date: Date) -> Int64? {
        safeInteger(floor(date.timeIntervalSince1970 / 900) * 900).map(Int64.init)
    }

    private static func trackingDate(_ database: OpaquePointer?) -> Date? {
        guard let query = UsageStatement(database, "SELECT value FROM meta WHERE key = ?"),
            query.bind([.text("tracking_since")]), sqlite3_step(query.handle) == SQLITE_ROW
        else { return nil }
        let seconds = sqlite3_column_double(query.handle, 0)
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static func storedModels(_ database: OpaquePointer?) -> Set<String> {
        guard let query = UsageStatement(database, "SELECT DISTINCT model FROM buckets") else {
            return []
        }
        var result: Set<String> = []
        while sqlite3_step(query.handle) == SQLITE_ROW { result.insert(query.text(0)) }
        return result
    }
}
