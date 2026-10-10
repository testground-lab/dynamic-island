import Foundation

struct ProjectIndexPublishing {
    var revision: Int64; var frontier: Int64; var cursor: Int64 = 0; var dataRevision: Int64
    var now: Date; var starts: [UsageRange: Date]; var state: ProjectUsageLogState
    var progress: ProjectUsageIndexProgress; var reports: [ProjectUsageIndexReport]
    var warnings: Set<String>; var lastResponse: Date?
}

extension ProjectUsageIndexStore {
    func reportKey(_ key: ProjectUsageReportKey) -> String { key.range.rawValue + "/" + (key.source?.rawValue ?? "all") }
    func beginPublication(now: Date, calendar: Calendar, state: ProjectUsageLogState, progress: ProjectUsageIndexProgress) throws -> Int64 {
        guard now.timeIntervalSince1970.isFinite else { throw ProjectUsageIndexStoreError.invalidMetadata }
        guard publication == nil else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
        if try progress.ready && hasPendingMaintenance() { throw ProjectUsageIndexStoreError.maintenancePending }
        // BEGIN alone does not pin SQLite's snapshot; the first read below does, BEFORE
        // capture of any frontier or context. Writer commits thereafter cannot reset it.
        try reader.run("BEGIN")
        do {
            let frontier = try reader.scalar("SELECT ordinal FROM winners ORDER BY ordinal DESC LIMIT 1")
            let warnings = try readWarnings(reader)
            var reports: [ProjectUsageIndexReport] = []
            for range in UsageRange.allCases {
                for source in [ProjectUsageSource?.none] + ProjectUsageSource.allCases.map(Optional.some) {
                    reports.append(.init(key: .init(range: range, source: source), totals: .init(), projectCount: 0))
                }
            }
            let revision = try writer.transaction { () -> Int64 in
                let revision = try nextSequence("revision")
                for report in reports {
                    try writer.run("INSERT INTO report_totals VALUES(?,?,?,?,?,?,?,?,?)", [.int(revision), .text(reportKey(report.key))] + report.totals.indexValues + [.int(0)])
                }
                try writer.run("UPDATE meta SET value=? WHERE key='staging'", [.int(revision)])
                return revision
            }
            publication = .init(revision: revision, frontier: frontier, dataRevision: try reader.scalar("SELECT value FROM meta WHERE key='data_revision'"), now: now,
                                starts: Dictionary(uniqueKeysWithValues: UsageRange.allCases.map { ($0, $0.start(now: now, calendar: calendar)) }),
                                state: state, progress: progress, reports: reports, warnings: warnings)
            return revision
        } catch { try? reader.run("ROLLBACK"); throw error }
    }
    func advancePublication(maxRecords: Int) throws -> ProjectUsageIndexPublication? {
        guard var current = publication else { throw ProjectUsageIndexStoreError.invalidCheckpoint }
        let budget = min(512, max(0, maxRecords))
        guard budget > 0 else { return nil }
        let q = try reader.query("SELECT \(Self.winnerColumns),ordinal FROM winners WHERE ordinal>? AND ordinal<=? ORDER BY ordinal LIMIT ?", [.int(current.cursor), .int(current.frontier), .int(Int64(budget))])
        var consumed = 0
        try writer.transaction {
            while try q.step() {
                consumed += 1
                let c = candidate(q)
                current.cursor = q.int(17)
                guard try eligible(c, db: reader) else { continue }
                let date = Date(timeIntervalSince1970: c.timestamp)
                if date > current.now { current.warnings.insert("Future-dated responses omitted"); continue }
                if current.lastResponse == nil || date > current.lastResponse! { current.lastResponse = date }
                var cwd = c.cwd
                if !c.cwdPresent {
                    let context = try reader.query("SELECT distinct_count,resolved FROM sessions WHERE source=? AND session=?", [.text(c.source), .text(c.session)])
                    if try context.step(), context.int(0) == 1 { cwd = context.text(1) }
                    else { cwd = "" }
                }
                let path = cwd.isEmpty ? "unattributed" : cwd
                for i in current.reports.indices {
                    let report = current.reports[i]
                    guard report.key.source == nil || report.key.source?.rawValue == c.source,
                          date >= current.starts[report.key.range]! else { continue }
                    let key = reportKey(report.key)
                    let old = try writer.query("SELECT \(Self.totalColumns) FROM report_groups WHERE revision=? AND report_key=? AND path=?", [.int(current.revision), .text(key), .text(path)])
                    let exists = try old.step()
                    let group = exists ? old.totals(0) : .init()
                    guard let total = report.totals.adding(c.totals), let grouped = group.adding(c.totals) else {
                        current.warnings.insert("Token aggregation overflow; affected responses omitted"); continue
                    }
                    let name = cwd.isEmpty ? "Unattributed" : (URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: cwd).lastPathComponent)
                    try writer.run("INSERT INTO report_groups(revision,report_key,path,name,\(Self.totalColumns),sort_tokens) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(revision,report_key,path) DO UPDATE SET responses=excluded.responses,input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,cache_write=excluded.cache_write,total=excluded.total,sort_tokens=excluded.sort_tokens", [.int(current.revision), .text(key), .text(path), .text(name)] + grouped.indexValues + [.int(-Int64(grouped.totalTokens))])
                    current.reports[i].totals = total
                    if !exists { current.reports[i].projectCount += 1 }
                    try writer.run("UPDATE report_totals SET responses=?,input=?,output=?,cache_read=?,cache_write=?,total=?,project_count=? WHERE revision=? AND report_key=?", total.indexValues + [.int(Int64(current.reports[i].projectCount)), .int(current.revision), .text(key)])
                }
            }
            // Cursor and group updates commit together. The in-memory copy is installed
            // only after success, so cancellation/SQL failure cannot double-apply rows.
            try writer.run("UPDATE meta SET value=? WHERE key='publication_cursor'", [.int(current.cursor)])
        }
        publication = current
        guard consumed < budget || current.cursor >= current.frontier else { return nil }
        try writer.transaction {
            let old = try writer.scalar("SELECT value FROM meta WHERE key='published'")
            try writer.run("UPDATE meta SET value=? WHERE key='published'", [.int(current.revision)])
            try writer.run("UPDATE meta SET value=0 WHERE key='staging'")
            if old != 0 { try enqueueCleanup(old) }
        }
        try reader.run("COMMIT")
        publication = nil
        var progress = current.progress
        progress.publishing = false
        // A pinned finite result remains useful, but must not claim fresh completeness
        // when a new repair/project job appeared while its snapshot was publishing.
        if try writer.scalar("SELECT value FROM meta WHERE key='data_revision'") != current.dataRevision { progress.ready = false }
        return .init(revision: current.revision, state: current.state, reports: current.reports,
                     warnings: current.warnings, lastResponse: current.lastResponse, progress: progress)
    }
    func cancelPublication() {
        guard let current = publication else { return }
        try? reader.run("ROLLBACK")
        do {
            try writer.transaction {
                try enqueueCleanup(current.revision)
                try writer.run("UPDATE meta SET value=0 WHERE key='staging'")
            }
        } catch { /* Durable staging marker makes reopen enqueue bounded cleanup. */ }
        publication = nil
    }
    func projectPage(key: ProjectUsageReportKey, cursor: ProjectUsageIndexPageCursor?, direction: ProjectUsageIndexPageDirection, pageSize: Int, revision: Int64) throws -> ProjectUsageIndexPage {
        guard revision > 0, try writer.scalar("SELECT value FROM meta WHERE key='published'") == revision else { throw ProjectUsageIndexStoreError.staleRevision }
        let size = min(20, max(1, pageSize)), report = reportKey(key)
        let countQuery = try writer.query("SELECT project_count FROM report_totals WHERE revision=? AND report_key=?", [.int(revision), .text(report)])
        guard try countQuery.step() else { throw ProjectUsageIndexStoreError.staleRevision }
        let projectCount = Int(countQuery.int(0))
        var values: [ProjectIndexValue] = [.int(revision), .text(report)]
        var predicate = "", order = "ASC"
        if let cursor {
            try validateText(cursor.path, limit: 4096)
            let op = direction == .next ? ">" : "<"
            predicate = " AND (sort_tokens,path) \(op) (?,?)"
            values += [.int(Int64(cursor.sortTokens)), .text(cursor.path)]
            if direction == .previous { order = "DESC" }
        }
        let q = try writer.query("SELECT path,name,\(Self.totalColumns),sort_tokens FROM report_groups WHERE revision=? AND report_key=?\(predicate) ORDER BY sort_tokens \(order),path \(order) LIMIT ?", values + [.int(Int64(size+1))])
        var tuples: [(ProjectUsageRow, ProjectUsageIndexPageCursor)] = []
        while try q.step() {
            let path = q.text(0), leaf = q.text(1)
            var name = leaf
            if path != "unattributed" {
                let duplicates = try writer.query("SELECT path FROM report_groups WHERE revision=? AND report_key=? AND name=? ORDER BY path LIMIT 2", [.int(revision), .text(report), .text(leaf)])
                var count = 0; while try duplicates.step() { count += 1 }
                if count > 1 { name += " — " + URL(fileURLWithPath: path).deletingLastPathComponent().path }
            }
            tuples.append((.init(id: path, name: name, path: path == "unattributed" ? nil : path, totals: q.totals(2)), .init(sortTokens: Int(q.int(8)), path: path)))
        }
        if tuples.count > size { tuples.removeLast() }
        if order == "DESC" { tuples.reverse() }
        func exists(_ cursor: ProjectUsageIndexPageCursor?, op: String) throws -> Bool {
            guard let cursor else { return false }
            return try writer.scalar("SELECT 1 FROM report_groups WHERE revision=? AND report_key=? AND (sort_tokens,path) \(op) (?,?) ORDER BY sort_tokens,path LIMIT 1", [.int(revision), .text(report), .int(Int64(cursor.sortTokens)), .text(cursor.path)]) == 1
        }
        let first = tuples.first?.1, last = tuples.last?.1
        return .init(revision: revision, key: key, pageSize: size, projectCount: projectCount, rows: tuples.map(\.0),
                     firstCursor: first, lastCursor: last, hasPrevious: try exists(first, op: "<"), hasNext: try exists(last, op: ">"))
    }
}
