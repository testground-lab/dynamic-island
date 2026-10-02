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

    private enum OpenResult {
        case ready(OpaquePointer)
        case failed(corrupt: Bool)
    }

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
            switch Self.open(url.path) {
            case .ready(let opened):
                handle = opened
                return
            case .failed(let corrupt):
                if corrupt, Self.moveAside(url), case .ready(let recreated) = Self.open(url.path) {
                    handle = recreated
                    return
                }
            }
        }
        if case .ready(let memory) = Self.open(":memory:") { handle = memory } else { handle = nil }
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

    private static func open(_ path: String) -> OpenResult {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            return .failed(corrupt: isCorrupt(result))
        }
        sqlite3_busy_timeout(database, 250)
        guard let check = UsageStatement(database, "PRAGMA quick_check(1)") else {
            let corrupt = isCorrupt(sqlite3_errcode(database))
            sqlite3_close_v2(database)
            return .failed(corrupt: corrupt)
        }
        let checkStatus = sqlite3_step(check.handle)
        guard checkStatus == SQLITE_ROW, check.text(0) == "ok" else {
            let corrupt = checkStatus == SQLITE_ROW || isCorrupt(checkStatus)
            sqlite3_close_v2(database)
            return .failed(corrupt: corrupt)
        }
        sqlite3_reset(check.handle)
        guard execute(database, "PRAGMA journal_mode = WAL"),
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
            let corrupt = isCorrupt(sqlite3_errcode(database))
            sqlite3_close_v2(database)
            return .failed(corrupt: corrupt)
        }
        return .ready(database)
    }

    private static func isCorrupt(_ code: Int32) -> Bool {
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func moveAside(_ url: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return false }
        let destination = url.appendingPathExtension("corrupt")
        // A bounded recovery history: replace this store's prior corrupt backup and sidecars.
        for suffix in ["", "-wal", "-shm"] {
            let old = URL(fileURLWithPath: destination.path + suffix)
            if files.fileExists(atPath: old.path) {
                do { try files.removeItem(at: old) } catch { return false }
            }
        }
        do { try files.moveItem(at: url, to: destination) } catch { return false }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if files.fileExists(atPath: sidecar.path) {
                try? files.moveItem(
                    at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
            }
        }
        // Clean backups made by the earlier UUID-suffixed recovery scheme as well.
        let siblings =
            (try? files.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey]
            )) ?? []
        for old in siblings
        where old.lastPathComponent.hasPrefix(destination.lastPathComponent + ".") {
            if (try? old.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? files.removeItem(at: old)
            }
        }
        return true
    }
}

/// Quarter-hour history containing routing identities and counters, never request payloads or keys.
public actor UsageStore {
    private let database: UsageDatabase
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    nonisolated let initialReports: [UsageRange: UsageReport]
    nonisolated let initialSeries: [UsageRange: UsageSeries]
    private var models: Set<String>
    private var lastPrunedAt: Date?
    private var dataVersion: Int
    private struct BucketKey: Hashable {
        let start: Int64
        let authIndex: String
        let model: String
    }

    private struct BucketAggregate {
        var provider: String
        var totals: UsageTotals

        mutating func merge(_ other: Self) {
            if !other.provider.isEmpty { provider = other.provider }
            totals = UsageTotals(
                requests: addingCounts(totals.requests, other.totals.requests),
                failed: addingCounts(totals.failed, other.totals.failed),
                inputTokens: addingCounts(totals.inputTokens, other.totals.inputTokens),
                outputTokens: addingCounts(totals.outputTokens, other.totals.outputTokens),
                totalTokens: addingCounts(totals.totalTokens, other.totals.totalTokens))
        }
    }

    private var pending: [BucketKey: BucketAggregate] = [:]
    private var collectionBeganAt: Date?

    public init(
        url: URL?, calendar: Calendar = .autoupdatingCurrent,
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
        let cutoff = Self.bucketStart(current.addingTimeInterval(-31 * 86400)) ?? 0
        var modelCache = Self.storedModels(database.handle, since: cutoff)
        self.collectionBeganAt = Self.trackingDate(database.handle)
        if !initialRecords.isEmpty {
            let aggregates = Self.aggregated(initialRecords, now: current)
            let result = Self.attemptIngest(
                aggregates, database: database.handle, now: current,
                trackingSince: self.collectionBeganAt ?? current,
                models: modelCache, prune: true,
                expectedVersion: Self.currentDataVersion(database.handle))
            if case .committed(_, let updated) = result {
                modelCache = updated
                self.lastPrunedAt = current
            } else {
                self.pending = Self.bounded(aggregates)
                self.collectionBeganAt = self.collectionBeganAt ?? current
            }
        }
        self.models = modelCache
        self.dataVersion = Self.currentDataVersion(database.handle)
        initialReports = Dictionary(
            uniqueKeysWithValues: UsageRange.allCases.map { range in
                (
                    range,
                    Self.report(
                        range, accounts: initialAccounts, now: current, calendar: calendar,
                        database: database.handle)
                )
            })
        initialSeries = Self.seriesAll(now: current, calendar: calendar, database: database.handle)
    }

    private enum IngestResult {
        case committed(changed: Bool, models: Set<String>)
        case failed(Int32)
    }

    /// Returns whether committed data changed, allowing the model to avoid unchanged report queries.
    /// A partially drained, unavailable endpoint can supply records without starting tracking.
    @discardableResult public func ingest(
        _ records: [UsageRecord], trackingAvailable: Bool = true
    ) -> Bool {
        let now = nowProvider()
        guard now.timeIntervalSince1970.isFinite else { return false }
        if trackingAvailable { collectionBeganAt = collectionBeganAt ?? now }
        var combined = pending
        for (key, aggregate) in Self.aggregated(records, now: now) {
            Self.merge(aggregate, into: &combined, at: key)
        }
        let prune = lastPrunedAt.map { now.timeIntervalSince($0) >= 3600 } ?? true
        let version = Self.currentDataVersion(database.handle)
        let externalChange = version != dataVersion
        var modelCache = models
        if externalChange, let cutoff = Self.bucketStart(now.addingTimeInterval(-31 * 86400)) {
            modelCache = Self.storedModels(database.handle, since: cutoff)
        }
        for attempt in 0..<2 {
            let result = Self.attemptIngest(
                combined, database: database.handle, now: now,
                trackingSince: collectionBeganAt,
                models: modelCache, prune: prune, expectedVersion: version)
            switch result {
            case .committed(let changed, let updated):
                pending = [:]
                models = updated
                dataVersion = Self.currentDataVersion(database.handle)
                if prune { lastPrunedAt = now }
                return changed || externalChange
            case .failed(let status):
                if status & 0xff == SQLITE_BUSY, attempt == 0 { continue }
                pending = Self.bounded(combined)
                return externalChange
            }
        }
        return false
    }

    private static func sanitized(_ records: [UsageRecord], now: Date) -> [UsageRecord] {
        records.compactMap { record in
            let timestamp = record.timestamp ?? now
            guard timestamp.timeIntervalSince1970.isFinite,
                timestamp >= now.addingTimeInterval(-31 * 86400)
            else { return nil }
            let raw =
                [record.model, record.alias].compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            var result = record
            result.timestamp = min(timestamp, now)
            result.model = String(raw.prefix(64))
            result.alias = nil
            result.authIndex = record.authIndex.map { String($0.prefix(64)) }
            result.provider = record.provider.map { String($0.prefix(64)) }
            return result
        }
    }

    private static func merge(
        _ aggregate: BucketAggregate, into buckets: inout [BucketKey: BucketAggregate],
        at key: BucketKey
    ) {
        if var existing = buckets[key] {
            existing.merge(aggregate)
            buckets[key] = existing
        } else {
            buckets[key] = aggregate
        }
    }

    private static func aggregated(_ records: [UsageRecord], now: Date)
        -> [BucketKey: BucketAggregate]
    {
        var buckets: [BucketKey: BucketAggregate] = [:]
        for record in sanitized(records, now: now) {
            guard let timestamp = record.timestamp, let start = bucketStart(timestamp) else {
                continue
            }
            let input = nonnegative(record.tokens?.inputTokens)
            let output = nonnegative(record.tokens?.outputTokens)
            let supplied = nonnegative(record.tokens?.totalTokens)
            let total = supplied > 0 ? supplied : addingCounts(
                addingCounts(input, output), nonnegative(record.tokens?.reasoningTokens))
            merge(
                BucketAggregate(
                    provider: record.provider ?? "",
                    totals: UsageTotals(
                        requests: 1, failed: record.failed == true ? 1 : 0,
                        inputTokens: input, outputTokens: output, totalTokens: total)),
                into: &buckets,
                at: BucketKey(
                    start: start, authIndex: record.authIndex ?? "", model: record.model ?? "unknown"))
        }
        return buckets
    }

    /// Sacrifice oldest model detail, never counters, when an outage spans too many keys.
    private static func bounded(_ aggregates: [BucketKey: BucketAggregate])
        -> [BucketKey: BucketAggregate]
    {
        let limit = 50_000
        guard aggregates.count > limit else { return aggregates }
        var buckets = aggregates
        let oldestFirst = aggregates.keys.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.authIndex != $1.authIndex { return $0.authIndex < $1.authIndex }
            return $0.model < $1.model
        }
        for key in oldestFirst where buckets.count > limit {
            guard key.model != "other", let aggregate = buckets.removeValue(forKey: key) else {
                continue
            }
            merge(aggregate, into: &buckets,
                  at: BucketKey(start: key.start, authIndex: key.authIndex, model: "other"))
        }
        // Single-model buckets cannot shrink further by model alone. Roll their oldest
        // time detail together per account; extreme account cardinality uses unattributed.
        let oldestStart = oldestFirst[0].start
        for key in oldestFirst where buckets.count > limit {
            let folded = BucketKey(start: key.start, authIndex: key.authIndex, model: "other")
            guard let aggregate = buckets.removeValue(forKey: folded) else { continue }
            merge(aggregate, into: &buckets,
                  at: BucketKey(start: oldestStart, authIndex: key.authIndex, model: "other"))
        }
        if buckets.count > limit {
            let overflow = BucketKey(start: oldestStart, authIndex: "", model: "other")
            for key in oldestFirst where buckets.count > limit {
                let folded = BucketKey(start: oldestStart, authIndex: key.authIndex, model: "other")
                guard folded != overflow, var aggregate = buckets.removeValue(forKey: folded) else {
                    continue
                }
                aggregate.provider = ""
                merge(aggregate, into: &buckets, at: overflow)
            }
        }
        return buckets
    }

    private static func attemptIngest(
        _ aggregates: [BucketKey: BucketAggregate], database: OpaquePointer?, now: Date,
        trackingSince: Date?, models: Set<String>, prune: Bool, expectedVersion: Int
    ) -> IngestResult {
        guard let database else { return .failed(SQLITE_CANTOPEN) }
        guard UsageDatabase.execute(database, "BEGIN IMMEDIATE") else {
            return .failed(sqlite3_errcode(database))
        }
        var committed = false
        defer { if !committed { _ = UsageDatabase.execute(database, "ROLLBACK") } }
        var changed = false
        if let trackingSince {
            guard UsageDatabase.execute(
                database,
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('tracking_since', ?)",
                [.real(trackingSince.timeIntervalSince1970)])
            else { return .failed(sqlite3_errcode(database)) }
            changed = sqlite3_changes(database) > 0
        }
        var modelCache = models
        let externalChange = currentDataVersion(database) != expectedVersion
        if !prune, externalChange, let oldest = bucketStart(now.addingTimeInterval(-31 * 86400)) {
            modelCache = storedModels(database, since: oldest)
            changed = true
        }
        if prune, let oldest = bucketStart(now.addingTimeInterval(-31 * 86400)) {
            guard
                UsageDatabase.execute(
                    database, "DELETE FROM buckets WHERE start < ?", [.integer(oldest)])
            else {
                return .failed(sqlite3_errcode(database))
            }
            changed = changed || sqlite3_changes(database) > 0
            modelCache = storedModels(database, since: oldest)
        }
        guard
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
        else { return .failed(sqlite3_errcode(database)) }
        for (key, aggregate) in aggregates {
            var model = key.model
            if !modelCache.contains(model),
                modelCache.count >= (modelCache.contains("other") ? 200 : 199)
            {
                model = "other"
            }
            modelCache.insert(model)
            let totals = aggregate.totals
            let values: [SQLValue] = [
                .integer(key.start), .text(key.authIndex), .text(aggregate.provider), .text(model),
                .integer(Int64(totals.requests)), .integer(Int64(totals.failed)),
                .integer(Int64(totals.inputTokens)), .integer(Int64(totals.outputTokens)),
                .integer(Int64(totals.totalTokens)),
            ]
            guard upsert.bind(values), upsert.run() else {
                return .failed(sqlite3_errcode(database))
            }
            changed = true
        }
        guard UsageDatabase.execute(database, "COMMIT") else {
            return .failed(sqlite3_errcode(database))
        }
        committed = true
        return .committed(changed: changed, models: modelCache)
    }

    nonisolated func dayStart(now: Date) -> Date { calendar.startOfDay(for: now) }

    nonisolated func hourStart(now: Date) -> Date {
        calendar.dateInterval(of: .hour, for: now)?.start ?? now
    }

    public func report(_ range: UsageRange, accounts: [Account], now: Date) -> UsageReport {
        Self.report(
            range, accounts: accounts, now: now, calendar: calendar, database: database.handle)
    }

    /// Like report, only committed buckets are visible; failed writes remain pending until retried.
    public func series(_ range: UsageRange, now: Date) -> UsageSeries {
        Self.series(range, now: now, calendar: calendar, database: database.handle)
    }

    /// Fetch all chart ranges from one committed 30-day bucket scan.
    public func seriesAll(now: Date) -> [UsageRange: UsageSeries] {
        Self.seriesAll(now: now, calendar: calendar, database: database.handle)
    }

    private struct SeriesRow {
        let start: Date
        let provider: Provider
        let totals: UsageTotals
    }

    private static func seriesRows(
        _ range: UsageRange, now: Date, calendar: Calendar, database: OpaquePointer?
    ) -> [SeriesRow] {
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
            let lower = bucketStart(range.start(now: now, calendar: calendar)),
            let upper = bucketStart(end),
            let query = UsageStatement(database, """
                SELECT start, provider, SUM(CAST(requests AS REAL)), SUM(CAST(failed AS REAL)),
                    SUM(CAST(input AS REAL)), SUM(CAST(output AS REAL)), SUM(CAST(total AS REAL))
                FROM buckets WHERE start >= ? AND start < ? GROUP BY start, provider
                """),
            query.bind([.integer(lower), .integer(upper)])
        else { return [] }
        var rows: [SeriesRow] = []
        while sqlite3_step(query.handle) == SQLITE_ROW {
            rows.append(SeriesRow(
                start: Date(timeIntervalSince1970: sqlite3_column_double(query.handle, 0)),
                provider: Provider(raw: query.text(1)), totals: query.totals(2)))
        }
        return rows
    }

    private static func seriesAll(
        now: Date, calendar: Calendar, database: OpaquePointer?
    ) -> [UsageRange: UsageSeries] {
        let trackingSince = trackingDate(database)
        let rows = seriesRows(.month, now: now, calendar: calendar, database: database)
        return Dictionary(uniqueKeysWithValues: UsageRange.allCases.map { range in
            (range, series(range, now: now, calendar: calendar, rows: rows,
                           trackingSince: trackingSince))
        })
    }

    private static func series(
        _ range: UsageRange, now: Date, calendar: Calendar, database: OpaquePointer?
    ) -> UsageSeries {
        series(range, now: now, calendar: calendar,
               rows: seriesRows(range, now: now, calendar: calendar, database: database),
               trackingSince: trackingDate(database))
    }

    private static func series(
        _ range: UsageRange, now: Date, calendar: Calendar, rows: [SeriesRow], trackingSince: Date?
    ) -> UsageSeries {
        let start = range.start(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today)
        else {
            return UsageSeries(range: range, granularity: range.granularity, points: [],
                               trackingSince: trackingSince)
        }
        var intervals: [(start: Date, end: Date)] = []
        var cursor = start
        while cursor < end {
            let next = range.granularity == .hour
                ? cursor.addingTimeInterval(3600)
                : calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
            guard next > cursor else { break }
            intervals.append((cursor, next))
            cursor = next
        }
        var bins = Array(repeating: [Provider: UsageTotals](), count: intervals.count)
        for row in rows {
            let bucket = row.start
            guard bucket >= start, bucket < end else { continue }
            let index: Int
            if range.granularity == .hour {
                index = Int(bucket.timeIntervalSince(start) / 3600)
            } else {
                // Upper bound on starts handles 23/25-hour local days without fixed-day arithmetic.
                var lower = 0
                var upper = intervals.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if intervals[middle].start <= bucket { lower = middle + 1 }
                    else { upper = middle }
                }
                index = lower - 1
            }
            guard bins.indices.contains(index), bucket < intervals[index].end else { continue }
            let provider = row.provider
            let totals = row.totals
            let previous = bins[index][provider] ?? .zero
            bins[index][provider] = UsageTotals(
                requests: addingCounts(previous.requests, totals.requests),
                inputTokens: addingCounts(previous.inputTokens, totals.inputTokens),
                outputTokens: addingCounts(previous.outputTokens, totals.outputTokens),
                totalTokens: addingCounts(previous.totalTokens, totals.totalTokens))
        }
        let points = intervals.enumerated().map { index, interval in
            UsageSeriesPoint(
                start: interval.start, end: interval.end,
                byProvider: bins[index].map { provider, totals in
                    ProviderTokens(provider: provider, inputTokens: totals.inputTokens,
                                   outputTokens: totals.outputTokens, totalTokens: totals.totalTokens,
                                   requests: totals.requests)
                }, trackingSince: trackingSince, now: now)
        }
        return UsageSeries(range: range, granularity: range.granularity, points: points,
                           trackingSince: trackingSince)
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
            SELECT auth_index, CASE WHEN auth_index = '' THEN '' ELSE MAX(provider) END, SUM(CAST(requests AS REAL)), SUM(CAST(failed AS REAL)),
                SUM(CAST(input AS REAL)), SUM(CAST(output AS REAL)), SUM(CAST(total AS REAL))
            FROM buckets WHERE start >= ? AND start <= ? GROUP BY auth_index
            """)
        var byAccount: [AccountUsage] = []
        if let query = accountQuery, query.bind(bounds) {
            while sqlite3_step(query.handle) == SQLITE_ROW {
                let index = query.text(0)
                let known = accounts.first { $0.authIndex == index && !index.isEmpty }
                let provider =
                    index.isEmpty
                    ? Provider.other("") : known?.provider ?? Provider(raw: query.text(1))
                let label =
                    known?.label
                    ?? (index.isEmpty
                        ? "Unattributed" : provider.displayName + " account · " + index.suffix(4))
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

    public func reset() {
        guard UsageDatabase.execute(database.handle, "BEGIN IMMEDIATE") else { return }
        if UsageDatabase.execute(database.handle, "DELETE FROM buckets"),
            UsageDatabase.execute(database.handle, "DELETE FROM meta"),
            UsageDatabase.execute(database.handle, "COMMIT")
        {
            models = []
            pending = [:]
            lastPrunedAt = nil
            collectionBeganAt = nil
            dataVersion = Self.currentDataVersion(database.handle)
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

    private static func currentDataVersion(_ database: OpaquePointer?) -> Int {
        guard let query = UsageStatement(database, "PRAGMA data_version"),
            sqlite3_step(query.handle) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int(query.handle, 0))
    }

    private static func storedModels(_ database: OpaquePointer?, since: Int64) -> Set<String> {
        guard
            let query = UsageStatement(
                database, "SELECT DISTINCT model FROM buckets WHERE start >= ?"),
            query.bind([.integer(since)])
        else {
            return []
        }
        var result: Set<String> = []
        while sqlite3_step(query.handle) == SQLITE_ROW { result.insert(query.text(0)) }
        return result
    }
}
