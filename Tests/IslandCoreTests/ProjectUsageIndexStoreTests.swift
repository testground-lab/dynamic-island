import Foundation
import Testing
import SQLite3
import Darwin
@testable import IslandCore

private let indexNow = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
private var indexCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
private var indexEmpty: ProjectUsageIndexBatch {
    .init(records: [], metadata: [], codexSessionIDs: [], codexCWDs: [], sawLegacy: false, sawCanonical: false, warnings: [])
}
private func indexSignature(_ size: Int64, inode: UInt64 = 1) -> ProjectUsageFileSignature {
    .init(device: UInt64.max, inode: inode, size: size, modifiedSeconds: 1, modifiedNanos: 2, changedSeconds: 3, changedNanos: 4)
}
private func indexFile(_ store: ProjectUsageIndexStore, source: ProjectUsageSource = .claudeCode, path: String = "/logs/a'quote.jsonl", size: Int64 = 100) throws -> ProjectUsageIndexedFile {
    let walk = try store.beginWalk(source: source, root: "/logs")
    return try store.registerFile(source: source, root: "/logs", path: path, signature: indexSignature(size), walkID: walk)
}
private func indexRecord(_ file: ProjectUsageIndexedFile, session: String = "session'quoted", response: String = "response'quoted", date: Date = indexNow, cwd: String? = "/projects/a", input: Int = 10, line: Int = 1) -> ProjectUsageRecord {
    .init(source: file.source, session: session, response: response, timestamp: date, explicitCWD: cwd,
          totals: .init(responses: 1, inputTokens: input, outputTokens: 2, cacheReadTokens: min(2,input), cacheWriteTokens: min(1,input), totalTokens: input+2), file: file.path, line: line)
}
private func indexBlocks(from: Int64 = 0, to: Int64) -> [ProjectUsagePrefixBlock] {
    guard to > from else { return [] }
    var blocks: [ProjectUsagePrefixBlock] = [], offset = from - from % 65536
    while offset < to {
        let length = Int(min(65536, to-offset))
        blocks.append(.init(offset: offset, length: length, digest: Data(repeating: UInt8(offset % 251), count: 32)))
        offset += Int64(length)
    }
    return blocks
}
private func indexCommit(_ store: ProjectUsageIndexStore, _ file: ProjectUsageIndexedFile, batch: ProjectUsageIndexBatch, offset: Int64? = nil, line: Int64? = nil, eof: Bool = true, unfinished: Bool = false) throws {
    let end = offset ?? file.highWaterSize
    try store.commit(fileID: file.id, generation: file.generation, batch: batch,
                     checkpoint: .init(expectedOffset: file.committedOffset, offset: end, line: line ?? max(file.committedLine, Int64(batch.records.map(\.line).max() ?? 1)),
                                       prefixBlocks: indexBlocks(from: file.committedOffset, to: end), reachedWatermark: eof, unfinishedRecord: unfinished))
}
private func indexSettle(_ store: ProjectUsageIndexStore, budget: Int = 1) throws {
    var calls = 0
    while try store.hasPendingMaintenance() {
        let result = try store.advanceMaintenance(maxRows: budget)
        #expect(result.processed <= budget)
        calls += 1
        guard calls < 50_000 else { throw ProjectUsageIndexStoreError.database }
    }
}
private func indexPublish(_ store: ProjectUsageIndexStore, now: Date = indexNow, calendar: Calendar = indexCalendar, budget: Int = 1, ready: Bool = true) throws -> ProjectUsageIndexPublication {
    if ready { try indexSettle(store) }
    _ = try store.beginPublication(now: now, calendar: calendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: ready))
    for _ in 0..<50_000 { if let result = try store.advancePublication(maxRecords: budget) { return result } }
    throw ProjectUsageIndexStoreError.database
}
private func indexReport(_ pub: ProjectUsageIndexPublication, range: UsageRange = .today, source: ProjectUsageSource? = nil) throws -> ProjectUsageIndexReport {
    try #require(pub.reports.first { $0.key == .init(range: range, source: source) })
}
private func indexRows(_ store: ProjectUsageIndexStore, _ pub: ProjectUsageIndexPublication, range: UsageRange = .today, source: ProjectUsageSource? = nil) throws -> [ProjectUsageRow] {
    var cursor: ProjectUsageIndexPageCursor?, rows: [ProjectUsageRow] = []
    for _ in 0..<5000 {
        let page = try store.projectPage(key: .init(range: range, source: source), cursor: cursor, direction: .next, pageSize: 20, revision: pub.revision)
        #expect(page.rows.count <= 20)
        rows += page.rows
        if !page.hasNext { return rows }
        cursor = page.lastCursor
    }
    throw ProjectUsageIndexStoreError.database
}

@Test func indexPersistenceResumeAndCheckpointCompareAndSwap() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-test-" + UUID().uuidString)
    let url = dir.appendingPathComponent("cache.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    var store: ProjectUsageIndexStore? = try .init(url: url)
    let file = try indexFile(store!, size: 200)
    var batch = indexEmpty; batch.records = [indexRecord(file)]
    try indexCommit(store!, file, batch: batch, offset: 100, line: 1, eof: false)
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) { try indexCommit(store!, file, batch: batch, offset: 100, line: 1, eof: false) }
    store = nil
    let reopened = try ProjectUsageIndexStore(url: url)
    let resumed = try reopened.nextFiles(source: .claudeCode, phase: .reading, limit: 1)[0]
    #expect(resumed.committedOffset == 100 && resumed.committedLine == 1)
    #expect(resumed.target.device == UInt64.max)
    batch.records = [indexRecord(resumed, response: "second", line: 2)]
    try indexCommit(reopened, resumed, batch: batch, line: 2)
    let pub = try indexPublish(reopened)
    #expect(try indexReport(pub).totals.responses == 2)
    #expect(try indexReport(pub).totals.inputTokens == 20)
}

@Test func indexRejectsStaleGenerationAndRollsBackWholeBatch() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    var batch = indexEmpty
    batch.records = [indexRecord(file), indexRecord(file, response: "bad", input: -1, line: 2)]
    #expect(throws: ProjectUsageIndexStoreError.invalidMetadata) { try indexCommit(store, file, batch: batch, line: 2) }
    #expect(try store.testSnapshot(maxRecords: 10).records.isEmpty)
    #expect(try store.file(file.id, file.generation).committedOffset == 0)
    let replacement = try store.invalidate(fileID: file.id, generation: file.generation, replacement: indexSignature(100, inode: 2))
    #expect(replacement.generation == 2)
    batch.records = [indexRecord(file)]
    #expect(throws: ProjectUsageIndexStoreError.staleGeneration) { try indexCommit(store, file, batch: batch) }
    #expect(try indexPublish(store).reports.allSatisfy { $0.totals.responses == 0 })
}

@Test func indexPrivacyBoundsBindingsAndPrivatePermissions() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    let cacheURL = store.url
    var batch = indexEmpty
    batch.records = [indexRecord(file, response: "x');DROP TABLE candidates;--", cwd: "DO_NOT_PERSIST")]
    batch.warnings = ["DO_NOT_PERSIST credential=secret"]
    try indexCommit(store, file, batch: batch)
    let pub = try indexPublish(store)
    #expect(try indexRows(store, pub).first?.path == nil)
    #expect(pub.warnings.contains("Local usage index incomplete"))
    for suffix in ["", "-wal", "-shm"] {
        let path = cacheURL.path + suffix
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self).contains("DO_NOT_PERSIST"))
    }
    let parentAttrs = try FileManager.default.attributesOfItem(atPath: cacheURL.deletingLastPathComponent().path)
    #expect((parentAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let invalid = try indexFile(store, path: "/logs/invalid", size: 100)
    batch.records = [indexRecord(invalid, session: String(repeating: "s", count: 4097))]
    #expect(throws: ProjectUsageIndexStoreError.invalidMetadata) { try indexCommit(store, invalid, batch: batch) }
}

@Test(arguments: ProjectUsageSource.allCases)
func indexSelectedIdentityBoundaryMatchesParser4096Bytes(source: ProjectUsageSource) throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, source: source)
    let session = String(repeating: "s'", count: 2048), response = String(repeating: "r'", count: 2048)
    var batch = indexEmpty
    batch.records = [indexRecord(file, session: session, response: response, cwd: nil)]
    if source == .codex { batch.codexSessionIDs = [session]; batch.codexCWDs = ["/boundary/project"] }
    else { batch.metadata = [.init(source: source, session: session, cwd: "/boundary/project")] }
    try indexCommit(store, file, batch: batch)
    let result = try indexPublish(store)
    #expect(try indexReport(result).totals.responses == 1)
    #expect(try indexRows(store, result).first?.path == "/boundary/project")
    let invalid = try indexFile(store, source: source, path: "/logs/invalid-boundary")
    batch = indexEmpty; batch.records = [indexRecord(invalid, response: response + "x")]
    #expect(throws: ProjectUsageIndexStoreError.invalidMetadata) { try indexCommit(store, invalid, batch: batch) }
}

@Test func indexMaintenanceContentChangeExcludesLargeReportCleanup() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, size: 8000)
    var batch = indexEmpty
    batch.records = (1...80).map { indexRecord(file, response: "r\($0)", cwd: "/projects/\($0)", line: $0) }
    try indexCommit(store, file, batch: batch, line: 80)
    _ = try indexPublish(store)
    _ = try indexPublish(store)
    #expect(try store.hasPendingMaintenance())
    let epoch = try store.writer.scalar("SELECT value FROM meta WHERE key='data_revision'")
    var processed = 0
    while try store.hasPendingMaintenance() {
        let result = try store.advanceMaintenance(maxRows: 1)
        #expect(result.processed == 1 && !result.contentChanged)
        processed += result.processed
        guard processed < 2000 else { throw ProjectUsageIndexStoreError.database }
    }
    #expect(processed > 512)
    #expect(try store.writer.scalar("SELECT value FROM meta WHERE key='data_revision'") == epoch)
    let idle = try store.advanceMaintenance(maxRows: 1)
    #expect(idle.processed == 0 && !idle.pending && !idle.contentChanged)
    #expect(!ProjectUsageIndexMaintenance(processed: 0, pending: false).contentChanged)
    _ = try store.invalidate(fileID: file.id, generation: 1, replacement: indexSignature(8000, inode: 2))
    let content = try store.advanceMaintenance(maxRows: 1)
    #expect(content.processed == 1 && content.pending && content.contentChanged)
    #expect(try store.writer.scalar("SELECT value FROM meta WHERE key='data_revision'") > epoch)
}

@Test func indexForeignAndCorruptDatabasesAreNotDeleted() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-foreign-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("foreign.sqlite")
    let db = try ProjectIndexDatabase(path: url.path)
    try db.run("CREATE TABLE foreign_table(value TEXT)"); try db.run("INSERT INTO foreign_table VALUES('DO_NOT_PERSIST')")
    #expect(throws: ProjectUsageIndexStoreError.schema) { _ = try ProjectUsageIndexStore(url: url) }
    #expect(try db.scalar("SELECT 1 FROM foreign_table LIMIT 1") == 1)
    let corrupt = dir.appendingPathComponent("corrupt.sqlite")
    let bytes = Data("not a database DO_NOT_PERSIST".utf8)
    try bytes.write(to: corrupt)
    #expect(throws: ProjectUsageIndexStoreError.database) { _ = try ProjectUsageIndexStore(url: corrupt) }
    #expect(try Data(contentsOf: corrupt) == bytes)
}

@Test func indexDeduplicatesLatestGloballyBeforeRangesAndConflicts() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    let a = try indexFile(store, path: "/logs/a"), z = try indexFile(store, path: "/logs/z")
    var batch = indexEmpty; batch.records = [indexRecord(a, cwd: "/one/app", input: 10)]
    try indexCommit(store, a, batch: batch)
    batch.records = [indexRecord(z, cwd: "/two/app", input: 20)]
    try indexCommit(store, z, batch: batch)
    let pub = try indexPublish(store)
    #expect(try indexReport(pub).totals.responses == 1)
    #expect(try indexReport(pub).totals.inputTokens == 20)
    #expect(try indexRows(store, pub).first?.path == "/two/app")
    #expect(pub.warnings.contains("Conflicting response snapshots; deterministic latest snapshot used"))
    let future = try indexFile(store, path: "/logs/future")
    batch.records = [indexRecord(future, date: indexNow.addingTimeInterval(60), input: 30)]
    try indexCommit(store, future, batch: batch)
    let futurePub = try indexPublish(store)
    #expect(try indexReport(futurePub).totals.responses == 0)
    #expect(futurePub.lastResponse == nil)
    #expect(futurePub.warnings.contains("Future-dated responses omitted"))
}

@Test func indexContextRefsAndExplicitPresenceRemainDistinct() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    let a = try indexFile(store, path: "/logs/a"), b = try indexFile(store, path: "/logs/b")
    var batch = indexEmpty
    batch.records = [indexRecord(a, response: "inferred", cwd: nil), indexRecord(a, response: "explicit-invalid", cwd: "invalid", line: 2), indexRecord(a, response: "worktree", cwd: "/one/app/.worktrees/topic", line: 3)]
    batch.metadata = [.init(source: .claudeCode, session: "session'quoted", cwd: "/one/./app")]
    try indexCommit(store, a, batch: batch, line: 3)
    batch.records = []; batch.metadata = [.init(source: .claudeCode, session: "session'quoted", cwd: "/two/app")]
    try indexCommit(store, b, batch: batch)
    var pub = try indexPublish(store)
    #expect(try indexRows(store, pub).first(where: { $0.path == nil })?.totals.responses == 2)
    try store.confirmAbsent(fileID: b.id, generation: b.generation)
    pub = try indexPublish(store)
    let rows = try indexRows(store, pub)
    #expect(rows.contains { $0.path == "/one/app" && $0.totals.responses == 1 })
    #expect(rows.contains { $0.path == nil && $0.totals.responses == 1 })
    #expect(rows.contains { $0.path == "/one/app/.worktrees/topic" })
}

@Test func indexCodexLateContextMultisessionSentinelAndCanonicalAppend() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    let file = try indexFile(store, source: .codex, size: 200)
    var batch = indexEmpty
    batch.records = [indexRecord(file, cwd: nil)]; batch.codexSessionIDs = ["session'quoted"]; batch.sawLegacy = true
    try indexCommit(store, file, batch: batch, offset: 100, line: 1, eof: false)
    #expect(!(try store.testSnapshot(maxRecords: 10).warnings).contains(where: { $0.contains("Legacy") }))
    var resumed = try store.file(file.id, file.generation)
    batch = indexEmpty; batch.codexCWDs = ["/late/project"]
    try indexCommit(store, resumed, batch: batch, line: 2)
    var pub = try indexPublish(store)
    #expect(try indexRows(store, pub).first?.path == "/late/project")
    #expect(pub.warnings.contains(where: { $0.contains("Legacy") }))
    resumed = try store.file(file.id, file.generation)
    try store.setTarget(fileID: file.id, generation: file.generation, signature: indexSignature(300), highWaterSize: 300, phase: .reading)
    resumed = try store.file(file.id, file.generation)
    batch = indexEmpty; batch.codexSessionIDs = ["second-session"]; batch.sawCanonical = true
    try indexCommit(store, resumed, batch: batch, line: 3)
    pub = try indexPublish(store)
    #expect(try indexRows(store, pub).first?.path == nil)
    #expect(!pub.warnings.contains(where: { $0.contains("Legacy") }))
    let clean = try indexFile(store, source: .codex, path: "/logs/clean")
    batch = indexEmpty; batch.codexSessionIDs = ["session'quoted"]; batch.codexCWDs = ["/late/project"]
    try indexCommit(store, clean, batch: batch)
    pub = try indexPublish(store)
    #expect(try indexRows(store, pub).first?.path == nil)
    try store.confirmAbsent(fileID: file.id, generation: file.generation)
    try indexSettle(store)
    #expect(try store.writer.scalar("SELECT distinct_count FROM sessions WHERE source='codex' AND session=?", [.text("session'quoted")]) == 1)
}

@Test func indexPrefixStagingVerificationAndFiniteGrowth() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, size: 131100)
    try store.stagePrefixBlocks(fileID: file.id, generation: file.generation, blocks: indexBlocks(to: 131072))
    #expect(try store.file(file.id, file.generation).committedOffset == 0)
    #expect(try store.prefixBlocks(fileID: file.id, generation: file.generation, fromOffset: 0, limit: 10).isEmpty)
    try store.commit(fileID: file.id, generation: file.generation, batch: indexEmpty,
                     checkpoint: .init(expectedOffset: 0, offset: 131100, line: 1, prefixBlocks: [.init(offset: 131072, length: 28, digest: Data(repeating: 8, count: 32))], reachedWatermark: true, unfinishedRecord: false))
    try store.queueGrowth(fileID: file.id, generation: file.generation, signature: indexSignature(200000))
    #expect(try store.file(file.id, file.generation).highWaterSize == 131100)
    try store.setTarget(fileID: file.id, generation: file.generation, signature: indexSignature(200000), highWaterSize: 200000, phase: .verifying)
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) { try store.finishVerification(fileID: file.id, generation: file.generation) }
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) { try store.checkpointVerification(fileID: file.id, generation: file.generation, expectedOffset: 1, offset: 65536) }
    try store.checkpointVerification(fileID: file.id, generation: file.generation, expectedOffset: 0, offset: 65536)
    try store.checkpointVerification(fileID: file.id, generation: file.generation, expectedOffset: 65536, offset: 131100)
    try store.finishVerification(fileID: file.id, generation: file.generation)
    #expect(try store.file(file.id, file.generation).phase == .reading)
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) { try store.setTarget(fileID: file.id, generation: file.generation, signature: indexSignature(300000), highWaterSize: 300000, phase: .reading) }
}

@Test func indexFailedWalkCannotReconcileAndSuccessfulAbsenceRetiresBoundedly() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    var batch = indexEmpty; batch.records = [indexRecord(file)]
    try indexCommit(store, file, batch: batch)
    let walk = try store.beginWalk(source: .claudeCode, root: "/logs")
    try store.finishWalk(source: .claudeCode, root: "/logs", walkID: walk, successful: false)
    #expect(try store.unseenFiles(source: .claudeCode, root: "/logs", walkID: walk, limit: 10).isEmpty)
    try store.finishWalk(source: .claudeCode, root: "/logs", walkID: walk, successful: true)
    #expect(try store.unseenFiles(source: .claudeCode, root: "/logs", walkID: walk, limit: 1).first?.id == file.id)
    try store.confirmAbsent(fileID: file.id, generation: file.generation)
    #expect(try store.hasPendingMaintenance())
    #expect(throws: ProjectUsageIndexStoreError.maintenancePending) { _ = try store.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: true)) }
    let partial = try indexPublish(store, ready: false)
    #expect(try indexReport(partial).totals.responses == 0)
    try indexSettle(store)
    #expect(try store.writer.scalar("SELECT 1 FROM candidates LIMIT 1") == 0)
    #expect(try store.unseenFiles(source: .claudeCode, root: "/logs", walkID: walk, limit: 1).isEmpty)
}

@Test func indexOneIdentityManyCopiesRepairsWithTinyBudgetsAndFollowup() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    var files: [ProjectUsageIndexedFile] = []
    for i in 0..<50 {
        let file = try indexFile(store, path: String(format: "/logs/%03d", i))
        var batch = indexEmpty; batch.records = [indexRecord(file, input: i+1)]
        try indexCommit(store, file, batch: batch); files.append(file)
    }
    try store.confirmAbsent(fileID: files[49].id, generation: 1)
    _ = try store.advanceMaintenance(maxRows: 1) // removes latest; starts finite repair.
    let replacement = try store.invalidate(fileID: files[48].id, generation: 1, replacement: indexSignature(100, inode: 22))
    var batch = indexEmpty; batch.records = [indexRecord(replacement, input: 70)]
    try indexCommit(store, replacement, batch: batch)
    let newest = try indexFile(store, path: "/logs/zzz")
    batch.records = [indexRecord(newest, input: 99)]
    try indexCommit(store, newest, batch: batch)
    try indexSettle(store)
    let pub = try indexPublish(store)
    #expect(try indexReport(pub).totals.inputTokens == 99)
    #expect(try indexReport(pub).totals.responses == 1)
    #expect(try store.writer.scalar("SELECT 1 FROM jobs LIMIT 1") == 0)
}

@Test func indexPinnedFinitePublicationCompletesUnderContinuousAppend() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, size: 1000)
    var batch = indexEmpty
    batch.records = (1...10).map { indexRecord(file, response: "r\($0)", cwd: "/p/\($0)", line: $0) }
    try indexCommit(store, file, batch: batch, line: 10)
    let revision = try store.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: true))
    var pub: ProjectUsageIndexPublication?
    for i in 0..<20 {
        let append = try indexFile(store, path: "/logs/append-\(i)")
        batch.records = [indexRecord(append, response: "append-\(i)", cwd: "/p/new")]
        try indexCommit(store, append, batch: batch)
        if let finished = try store.advancePublication(maxRecords: 1) { pub = finished; break }
    }
    let result = try #require(pub)
    #expect(result.revision == revision && !result.progress.ready)
    #expect(try indexReport(result).totals.responses == 10)
    #expect(try indexRows(store, result).count == 10)
    #expect(try indexReport(indexPublish(store)).totals.responses > 10)
}

@Test func indexCancellationRollbackAndReopenDiscardStaging() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-cancel-" + UUID().uuidString)
    let url = dir.appendingPathComponent("cache.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    var store: ProjectUsageIndexStore? = try .init(url: url)
    let file = try indexFile(store!, size: 200)
    var batch = indexEmpty; batch.records = [indexRecord(file), indexRecord(file, response: "two", line: 2)]
    try indexCommit(store!, file, batch: batch, line: 2)
    _ = try store!.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: true))
    #expect(try store!.advancePublication(maxRecords: 1) == nil)
    store!.cancelPublication()
    #expect(try indexReport(indexPublish(store!)).totals.responses == 2)
    _ = try store!.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: false))
    _ = try store!.advancePublication(maxRecords: 1)
    store = nil
    let reopened = try ProjectUsageIndexStore(url: url)
    #expect(try reopened.hasPendingMaintenance())
    #expect(try indexReport(indexPublish(reopened)).totals.responses == 2)
    #expect(try reopened.writer.scalar("SELECT value FROM meta WHERE key='staging'") == 0)
}

@Test func indexKeysetPagesAllProjectsStableTotalsReverseAndStaleRevision() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, size: 7000)
    var batch = indexEmpty
    batch.records = (1...65).map { indexRecord(file, session: "s\($0)", response: "r\($0)", cwd: "/projects/\(String(format: "%03d", $0))/app", input: $0, line: $0) }
    try indexCommit(store, file, batch: batch, line: 65)
    let pub = try indexPublish(store)
    let first = try store.projectPage(key: .init(range: .today, source: nil), cursor: nil, direction: .next, pageSize: 999, revision: pub.revision)
    #expect(first.rows.count == 20 && !first.hasPrevious && first.hasNext)
    let second = try store.projectPage(key: first.key, cursor: first.lastCursor, direction: .next, pageSize: 20, revision: pub.revision)
    let previous = try store.projectPage(key: first.key, cursor: second.firstCursor, direction: .previous, pageSize: 20, revision: pub.revision)
    #expect(previous.rows == first.rows)
    let rows = try indexRows(store, pub)
    #expect(rows.count == 65 && Set(rows.map(\.id)).count == 65)
    #expect(rows.first?.name == "app — /projects/065")
    #expect(try indexReport(pub).projectCount == 65)
    #expect(rows.reduce(0) { $0 + $1.totals.totalTokens } == (try indexReport(pub).totals.totalTokens))
    _ = try indexPublish(store)
    #expect(throws: ProjectUsageIndexStoreError.staleRevision) { _ = try store.projectPage(key: first.key, cursor: nil, direction: .next, pageSize: 20, revision: pub.revision) }
}

@Test func indexHundredsOfContextProjectsMatchReducerAndClockRollbackWithoutReread() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    for source in ProjectUsageSource.allCases {
        let file = try indexFile(store, source: source, path: "/logs/\(source.rawValue)", size: 60000)
        var batch = indexEmpty
        for i in 1...200 {
            let session = "s\(i)", date = indexNow.addingTimeInterval(-Double(i % 190) * 86400)
            batch.records.append(indexRecord(file, session: session, response: "r\(i)", date: date, cwd: nil, input: i, line: i))
            batch.metadata.append(.init(source: source, session: session, cwd: "/project/\(i)"))
        }
        try indexCommit(store, file, batch: batch, line: 200)
    }
    for now in [indexNow, indexNow.addingTimeInterval(86400*200), indexNow] {
        let pub = try indexPublish(store, now: now)
        let reference = ProjectUsageReducer.publish(try store.testSnapshot(maxRecords: 1000), now: now, calendar: indexCalendar)
        for report in pub.reports {
            #expect(report.totals == reference.reports[report.key]?.totals)
            #expect(try indexRows(store, pub, range: report.key.range, source: report.key.source) == reference.reports[report.key]?.projects)
        }
    }
}

@Test func indexAggregationOverflowOmitsOnlyAffectedReportWithoutSQLiteSum() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    var batch = indexEmpty
    batch.records = [indexRecord(file, response: "huge", input: Int.max-2), indexRecord(file, response: "small", line: 2)]
    try indexCommit(store, file, batch: batch, line: 2)
    let pub = try indexPublish(store)
    #expect(try indexReport(pub).totals.responses == 1)
    #expect(try indexReport(pub).totals.totalTokens == Int.max)
    #expect(pub.warnings.contains("Token aggregation overflow; affected responses omitted"))
}

@Test func indexQueryPlansUseSeekIndexesWithoutTemporarySorts() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    let queries = [
        "SELECT id FROM candidates WHERE source='codex' AND session='s' AND response='r' AND id>0 AND id<=100 ORDER BY id LIMIT 1",
        "SELECT ordinal FROM winners WHERE ordinal>0 AND ordinal<=100 ORDER BY ordinal LIMIT 1",
        "SELECT path FROM report_groups WHERE revision=1 AND report_key='today/all' AND (sort_tokens,path)>(-20,'/p') ORDER BY sort_tokens,path LIMIT 21",
        "SELECT id FROM files WHERE source='codex' AND phase='complete' AND present=1 ORDER BY served,id LIMIT 1",
        "SELECT id FROM bindings WHERE file_id=1 AND gen=1 AND id>0 ORDER BY id LIMIT 1",
        "SELECT id FROM facts WHERE file_id=1 AND gen=1 AND kind=1 AND id>0 AND id<=100 ORDER BY id LIMIT 1"
    ]
    for sql in queries {
        let q = try store.writer.query("EXPLAIN QUERY PLAN " + sql)
        var plans: [String] = []; while try q.step() { plans.append(q.text(3)) }
        #expect(plans.contains { $0.contains("SEARCH") })
        #expect(!plans.contains { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN ") })
    }
}

@Test func indexStagedAppendHashDoesNotOverwriteCommittedShortPrefix() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    try indexCommit(store, file, batch: indexEmpty)
    try store.setTarget(fileID: file.id, generation: 1, signature: indexSignature(70000), highWaterSize: 70000, phase: .reading)
    let fullDigest = Data(repeating: 99, count: 32)
    try store.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 0, length: 65536, digest: fullDigest)])
    let before = try #require(try store.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2).first)
    #expect(before.length == 100 && before.digest == Data(repeating: 0, count: 32))
    try store.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                     checkpoint: .init(expectedOffset: 100, offset: 70000, line: 2, prefixBlocks: [.init(offset: 65536, length: 4464, digest: Data(repeating: 5, count: 32))], reachedWatermark: true, unfinishedRecord: false))
    let after = try store.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2)
    #expect(after.count == 2 && after[0].length == 65536 && after[0].digest == fullDigest)
    #expect(after[1].length == 4464)
}

@Test func indexShortCheckpointRetainsEarlierStagedFullHashThroughAppendAndReopen() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-short-staged-" + UUID().uuidString)
    let url = dir.appendingPathComponent("cache.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    var store: ProjectUsageIndexStore? = try .init(url: url)
    let file = try indexFile(store!, size: 100000)
    let full = Data(repeating: 70, count: 32), short = Data(repeating: 71, count: 32), tail = Data(repeating: 72, count: 32)
    try store!.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 0, length: 65536, digest: full)])
    try store!.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                      checkpoint: .init(expectedOffset: 0, offset: 100, line: 1, prefixBlocks: [.init(offset: 0, length: 100, digest: short)], reachedWatermark: false, unfinishedRecord: false))
    let first = try #require(try store!.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 1).first)
    #expect(first.length == 100 && first.digest == short)
    try store!.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                      checkpoint: .init(expectedOffset: 100, offset: 100000, line: 2, prefixBlocks: [.init(offset: 65536, length: 34464, digest: tail)], reachedWatermark: true, unfinishedRecord: false))
    let hashes = try store!.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2)
    #expect(hashes.count == 2)
    #expect(hashes[0].offset == 0 && hashes[0].length == 65536 && hashes[0].digest == full)
    #expect(hashes[1].offset == 65536 && hashes[1].length == 34464 && hashes[1].digest == tail)
    store = nil
    let reopened = try ProjectUsageIndexStore(url: url)
    let persisted = try reopened.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2)
    #expect(persisted.map(\.offset) == [0, 65536])
    #expect(persisted.map(\.length) == [65536, 34464])
    #expect(persisted.map(\.digest) == [full, tail])
}

@Test(arguments: ProjectUsageSource.allCases)
func index513ByteIdentityDoesNotBlockOtherNormalizedRecords(source: ProjectUsageSource) throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, source: source)
    var batch = indexEmpty
    let session = String(repeating: "s", count: 513), response = String(repeating: "r", count: 513)
    batch.records = [indexRecord(file, session: session, response: response), indexRecord(file, session: session, response: "ordinary-response", line: 2)]
    try indexCommit(store, file, batch: batch, line: 2)
    let result = try indexPublish(store)
    #expect(try indexReport(result).totals.responses == 2)
    #expect(try store.file(file.id, 1).committedLine == 2)
}

@Test func indexReopenRejectsStaleUncommittedSuffixHashAndRequiresFreshCoverage() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-hash-reopen-" + UUID().uuidString)
    let url = dir.appendingPathComponent("cache.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    var store: ProjectUsageIndexStore? = try .init(url: url)
    let file = try indexFile(store!)
    try indexCommit(store!, file, batch: indexEmpty)
    try store!.setTarget(fileID: file.id, generation: 1, signature: indexSignature(65536), highWaterSize: 65536, phase: .reading)
    try store!.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 0, length: 65536, digest: Data(repeating: 77, count: 32))])
    store = nil
    let reopened = try ProjectUsageIndexStore(url: url)
    let checkpoint = ProjectUsageIndexCheckpoint(expectedOffset: 100, offset: 65536, line: 2, prefixBlocks: [], reachedWatermark: true, unfinishedRecord: false)
    // The log's suffix may have changed after byte100. Reopen cannot trust the old
    // staged digest merely because the committed first100 bytes still verify.
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) { try reopened.commit(fileID: file.id, generation: 1, batch: indexEmpty, checkpoint: checkpoint) }
    #expect(try reopened.file(file.id, 1).committedOffset == 100)
    let before = try #require(try reopened.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 1).first)
    #expect(before.length == 100 && before.digest == Data(repeating: 0, count: 32))
    let fresh = Data(repeating: 88, count: 32)
    try reopened.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 0, length: 65536, digest: fresh)])
    try reopened.commit(fileID: file.id, generation: 1, batch: indexEmpty, checkpoint: checkpoint)
    #expect(try reopened.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 1).first?.digest == fresh)
}

@Test func indexReopenPreservesLogicallyCommittedPendingHashesAndRejectsStageGap() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-hash-preserve-" + UUID().uuidString)
    let url = dir.appendingPathComponent("cache.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    var store: ProjectUsageIndexStore? = try .init(url: url)
    let file = try indexFile(store!)
    try indexCommit(store!, file, batch: indexEmpty)
    try store!.setTarget(fileID: file.id, generation: 1, signature: indexSignature(131072), highWaterSize: 131072, phase: .reading)
    let digest = Data(repeating: 33, count: 32)
    try store!.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 0, length: 65536, digest: digest)])
    try store!.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                      checkpoint: .init(expectedOffset: 100, offset: 65536, line: 2, prefixBlocks: [], reachedWatermark: false, unfinishedRecord: false))
    try store!.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 65536, length: 65536, digest: Data(repeating: 44, count: 32))])
    store = nil
    let reopened = try ProjectUsageIndexStore(url: url)
    let committed = try reopened.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2)
    #expect(committed.count == 1 && committed[0].length == 65536 && committed[0].digest == digest)
    #expect(throws: ProjectUsageIndexStoreError.invalidCheckpoint) {
        try reopened.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                            checkpoint: .init(expectedOffset: 65536, offset: 131072, line: 3, prefixBlocks: [], reachedWatermark: true, unfinishedRecord: false))
    }
    // The second full block must be freshly supplied; the first committed one is
    // still readable without promotion of every hash row during cache opening.
    try reopened.stagePrefixBlocks(fileID: file.id, generation: 1, blocks: [.init(offset: 65536, length: 65536, digest: Data(repeating: 55, count: 32))])
    try reopened.commit(fileID: file.id, generation: 1, batch: indexEmpty,
                        checkpoint: .init(expectedOffset: 65536, offset: 131072, line: 3, prefixBlocks: [], reachedWatermark: true, unfinishedRecord: false))
    #expect(try reopened.prefixBlocks(fileID: file.id, generation: 1, fromOffset: 0, limit: 2).first?.digest == digest)
}

@Test func indexPublicationHasIndependentHard512RecordLimit() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, size: 60000)
    var batch = indexEmpty
    batch.records = (1...600).map { indexRecord(file, response: "r\($0)", line: $0) }
    try indexCommit(store, file, batch: batch, line: 600)
    _ = try store.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: true))
    #expect(try store.advancePublication(maxRecords: Int.max) == nil)
    let cursor = try #require(store.publication?.cursor)
    #expect(try store.reader.scalar("SELECT COUNT(*) FROM winners WHERE ordinal<=?", [.int(cursor)]) == 512)
    #expect(store.publication?.reports.first?.totals.responses == 512)
    let result = try #require(try store.advancePublication(maxRecords: Int.max))
    #expect(try indexReport(result).totals.responses == 600)
}

@Test func indexPublicationSQLFailureRollsBackGroupsTotalsAndCursorBeforeRetry() throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    var batch = indexEmpty; batch.records = [indexRecord(file)]
    try indexCommit(store, file, batch: batch)
    _ = try store.beginPublication(now: indexNow, calendar: indexCalendar, state: .loaded, progress: .init(sources: [], publishing: true, ready: true))
    try store.writer.run("CREATE TEMP TRIGGER fail_publication BEFORE INSERT ON report_groups WHEN NEW.report_key='today/claudeCode' BEGIN SELECT RAISE(ABORT,'private diagnostic'); END")
    #expect(throws: ProjectUsageIndexStoreError.database) { _ = try store.advancePublication(maxRecords: 1) }
    #expect(store.publication?.cursor == 0)
    #expect(try store.writer.scalar("SELECT 1 FROM report_groups LIMIT 1") == 0)
    try store.writer.run("DROP TRIGGER fail_publication")
    let result = try #require(try store.advancePublication(maxRecords: 1))
    #expect(try indexReport(result).totals.responses == 1)
    #expect(try indexRows(store, result).first?.totals.responses == 1)
}

@Test(arguments: ["UTC", "America/New_York", "Australia/Lord_Howe"])
func indexCalendarBoundariesUseProvidedCalendar(zone: String) throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: zone))
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store)
    let start = calendar.startOfDay(for: indexNow)
    var batch = indexEmpty
    batch.records = [indexRecord(file, response: "boundary", date: start), indexRecord(file, response: "before", date: start.addingTimeInterval(-1), line: 2)]
    try indexCommit(store, file, batch: batch, line: 2)
    let result = try indexPublish(store, calendar: calendar)
    #expect(try indexReport(result).totals.responses == 1)
    #expect(try indexReport(result, range: .week).totals.responses == 2)
}

@Test func indexUnsafeSidecarIsRejectedWithoutTouchingTarget() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-sidecar-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("user-history"), url = dir.appendingPathComponent("cache.sqlite")
    try Data("private history".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(atPath: url.path + "-wal", withDestinationPath: target.path)
    #expect(throws: ProjectUsageIndexStoreError.database) { _ = try ProjectUsageIndexStore(url: url) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "private history")
    #expect(((try FileManager.default.attributesOfItem(atPath: target.path))[.posixPermissions] as? NSNumber)?.intValue == 0o644)
}

@Test func indexCurrentWalkScheduleCannotHideJobsBehindOldRootsOrWalks() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    for i in 0..<100 { _ = try indexFile(store, path: "/logs/old-\(i)") }
    let currentWalk = try store.beginWalk(source: .claudeCode, root: "/current")
    let a = try store.registerFile(source: .claudeCode, root: "/current", path: "/current/a", signature: indexSignature(100), walkID: currentWalk)
    let b = try store.registerFile(source: .claudeCode, root: "/current", path: "/current/b", signature: indexSignature(100), walkID: currentWalk)
    #expect(try store.nextFiles(source: .claudeCode, root: "/current", walkID: currentWalk, phase: .queued, limit: 1).first?.id == a.id)
    try store.markServed(fileID: a.id, generation: 1)
    #expect(try store.nextFiles(source: .claudeCode, root: "/current", walkID: currentWalk, phase: .queued, limit: 1).first?.id == b.id)
    #expect(try store.nextFiles(source: .claudeCode, root: "/current", walkID: currentWalk+1, phase: .queued, limit: 20).isEmpty)
    let newerWalk = try store.beginWalk(source: .claudeCode, root: "/current")
    _ = try store.registerFile(source: .claudeCode, root: "/current", path: "/current/a", signature: indexSignature(100), walkID: newerWalk)
    #expect(try store.nextFiles(source: .claudeCode, root: "/current", walkID: newerWalk, phase: .queued, limit: 1).first?.id == a.id)
    let plan = try store.writer.query("EXPLAIN QUERY PLAN SELECT id FROM files WHERE source='claudeCode' AND root='/current' AND walk_id=1 AND phase='queued' AND present=1 ORDER BY served,id LIMIT 1")
    var details: [String] = []; while try plan.step() { details.append(plan.text(3)) }
    #expect(details.contains { $0.contains("SEARCH") && $0.contains("file_walk_schedule") })
    #expect(!details.contains { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN ") })
}

@Test func indexGenerationWarningsRetireWithRefcountsAndKeepOtherFilesWarning() throws {
    let store = try ProjectUsageIndexStore(url: nil)
    let a = try indexFile(store, path: "/logs/a"), b = try indexFile(store, path: "/logs/b")
    let warning = "Malformed Claude Code log lines skipped"
    var batch = indexEmpty; batch.warnings = [warning, "Unsupported Claude Code usage record format"]
    try indexCommit(store, a, batch: batch)
    batch.warnings = [warning]
    try indexCommit(store, b, batch: batch)
    #expect(try store.writer.scalar("SELECT refs FROM warnings WHERE message=?", [.text(warning)]) == 2)
    let replacement = try store.invalidate(fileID: a.id, generation: 1, replacement: indexSignature(100, inode: 2))
    try indexSettle(store)
    #expect(try store.writer.scalar("SELECT refs FROM warnings WHERE message=?", [.text(warning)]) == 1)
    #expect(!(try store.testSnapshot(maxRecords: 10).warnings).contains("Unsupported Claude Code usage record format"))
    #expect((try store.testSnapshot(maxRecords: 10).warnings).contains(warning))
    try store.confirmAbsent(fileID: b.id, generation: 1)
    try indexSettle(store)
    try indexCommit(store, replacement, batch: indexEmpty)
    #expect(try store.testSnapshot(maxRecords: 10).warnings.isEmpty)
    #expect(try store.writer.scalar("SELECT 1 FROM warning_bindings LIMIT 1") == 0)
    #expect(try store.writer.scalar("SELECT 1 FROM warnings LIMIT 1") == 0)
}

@Test(arguments: ProjectUsageSource.allCases)
func indexAwaitingNewlineWarningIsDerivedAndClearsWhenCaughtUp(source: ProjectUsageSource) throws {
    let store = try ProjectUsageIndexStore(url: nil), file = try indexFile(store, source: source, size: 200)
    let warning = "\(source.title) unfinished log line deferred"
    var batch = indexEmpty; batch.warnings = [warning]
    try indexCommit(store, file, batch: batch, offset: 100, line: 1, unfinished: true)
    #expect((try store.testSnapshot(maxRecords: 10).warnings).contains(warning))
    #expect(try store.writer.scalar("SELECT 1 FROM warning_bindings WHERE message=? LIMIT 1", [.text(warning)]) == 0)
    let resumed = try store.file(file.id, 1)
    try indexCommit(store, resumed, batch: batch, line: 2)
    #expect(!(try store.testSnapshot(maxRecords: 10).warnings).contains(warning))
    let plan = try store.writer.query("EXPLAIN QUERY PLAN SELECT 1 FROM files WHERE source='codex' AND phase='awaitingNewline' AND present=1 AND eligible=1 ORDER BY id LIMIT 1")
    var details: [String] = []; while try plan.step() { details.append(plan.text(3)) }
    #expect(details.contains { $0.contains("SEARCH") && $0.contains("file_deferred") })
    #expect(!details.contains { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN ") })
}

@Test func indexSchedulingOldestServedNotModificationAndEphemeralCleanup() throws {
    var store: ProjectUsageIndexStore? = try .init(url: nil)
    let url = store!.url
    let a = try indexFile(store!, path: "/logs/a"), b = try indexFile(store!, path: "/logs/b")
    #expect(try store!.nextFiles(source: .claudeCode, phase: .queued, limit: 1).first?.id == a.id)
    try store!.markServed(fileID: a.id, generation: 1)
    #expect(try store!.nextFiles(source: .claudeCode, phase: .queued, limit: 1).first?.id == b.id)
    store = nil
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
}
