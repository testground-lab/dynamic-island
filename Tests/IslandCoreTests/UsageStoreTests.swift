import Foundation
import SQLite3
import Testing

@testable import IslandCore

private let reference = Fixtures.referenceNow
private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
private func sample(
    _ model: String = "model", at date: Date = reference, index: String? = nil,
    provider: String = "claude", failed: Bool = false,
    input: Int = 10, output: Int = 20, reasoning: Int = 5, total: Int = 0
) -> UsageRecord {
    var record = UsageRecord(
        timestamp: date, model: model, failed: failed,
        tokens: UsageTokens(
            inputTokens: input, outputTokens: output,
            reasoningTokens: reasoning, totalTokens: total))
    record.authIndex = index
    record.provider = provider
    return record
}
private func knownAccounts() throws -> [Account] {
    let files = try JSONDecoder().decode(AuthFilesResponse.self, from: Fixtures.data("auth-files"))
    return AccountMapper.accounts(from: files, live: [:], now: reference)
}
private func databaseURL() throws -> URL {
    let directory = URL(
        fileURLWithPath: "/Users/ksotis/workspace/tools/dynamic-island/.build/core-sql-tests/"
            + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("usage.sqlite")
}
private func sqliteInteger(_ url: URL, sql: String) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let database { sqlite3_close_v2(database) }
        throw StoreTestError.sqlite
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw StoreTestError.sqlite
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreTestError.sqlite }
    return sqlite3_column_int64(statement, 0)
}
private enum StoreTestError: Error { case sqlite }
private final class StoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = reference
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@Test func usageRangeTitlesAndCalendarBoundaries() {
    #expect(UsageRange.allCases.map(\.title) == ["Today", "7d", "30d"])
    #expect(
        UsageRange.today.start(now: reference, calendar: utc())
            == APIDateParser.parse("2026-10-02T00:00:00Z"))
    #expect(
        UsageRange.week.start(now: reference, calendar: utc())
            == APIDateParser.parse("2026-09-26T00:00:00Z"))
    #expect(
        UsageRange.month.start(now: reference, calendar: utc())
            == APIDateParser.parse("2026-09-03T00:00:00Z"))
}

@Test func usageRangesRespectDaylightSavingTransitions() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let spring = APIDateParser.parse("2026-03-10T12:00:00Z")!
    #expect(
        UsageRange.today.start(now: spring, calendar: calendar)
            == APIDateParser.parse("2026-03-10T04:00:00Z"))
    #expect(
        UsageRange.week.start(now: spring, calendar: calendar)
            == APIDateParser.parse("2026-03-04T05:00:00Z"))
    #expect(
        UsageRange.month.start(now: spring, calendar: calendar)
            == APIDateParser.parse("2026-02-09T05:00:00Z"))
    let fall = APIDateParser.parse("2026-11-03T12:00:00Z")!
    let today = UsageRange.today.start(now: fall, calendar: calendar)
    let week = UsageRange.week.start(now: fall, calendar: calendar)
    #expect(today.timeIntervalSince(week) == 6 * 86400 + 3600)
}

@Test func quarterHourBucketsMergeAndFloorRequestBoundaries() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let now = reference.addingTimeInterval(7 * 60 + 31)
    let store = UsageStore(url: url, calendar: utc(), now: { now })
    await store.ingest([
        sample(at: reference.addingTimeInterval(60)),
        sample(at: reference.addingTimeInterval(14 * 60)),  // future is clamped into the current bucket
        sample(at: reference.addingTimeInterval(-1)),
    ])
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 2)
    #expect(
        try sqliteInteger(url, sql: "SELECT MAX(start) FROM buckets")
            == Int64(reference.timeIntervalSince1970))
    #expect(
        try sqliteInteger(url, sql: "SELECT MIN(start) FROM buckets")
            == Int64(reference.timeIntervalSince1970 - 900))
    #expect(try sqliteInteger(url, sql: "PRAGMA user_version") == 1)
    #expect(
        try sqliteInteger(
            url, sql: "SELECT COUNT(*) FROM pragma_journal_mode WHERE journal_mode = 'wal'") == 1)
}

@Test func usageReportsAttributeAccountsModelsAndLabels() async throws {
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    await store.ingest([
        sample("alpha", index: "fake-claude-1", total: 10),
        sample("alpha", index: "fake-claude-1", failed: true, total: 30),
        sample("beta", index: "fake-config-key", provider: "codex", total: 20),
        sample("alpha", total: 5),
    ])
    let report = await store.report(.today, accounts: try knownAccounts(), now: reference)
    #expect(
        report.totals
            == UsageTotals(
                requests: 4, failed: 1, inputTokens: 40, outputTokens: 80, totalTokens: 65))
    #expect(report.byAccount.map(\.id) == ["fake-claude-1", "fake-config-key", "unattributed"])
    #expect(
        report.byAccount.map(\.label) == [
            "alice@example.com", "Codex account · -key", "Unattributed",
        ])
    #expect(report.byAccount[0].provider == .claude)
    #expect(report.byAccount[1].provider == .codex)
    #expect(report.byAccount[2].authIndex == nil)
    #expect(report.byAccount[2].provider == .other(""))
    #expect(report.byModel.map(\.model) == ["alpha", "beta"])
    #expect(report.byModel[0].requests == 3)
    #expect(report.byModel[0].totalTokens == 45)
}

@Test func tokenFallbackAliasAndNegativeValuesAreDefensive() async {
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    var alias = sample("")
    alias.alias = "alias"
    var unknown = sample("")
    unknown.alias = nil
    await store.ingest([
        alias, unknown,
        sample("explicit", input: 100, output: 200, total: 2),
        sample("negative", input: -10, output: 5, reasoning: -1),
    ])
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.byModel.first { $0.model == "alias" }?.totalTokens == 35)
    #expect(report.byModel.first { $0.model == "unknown" }?.totalTokens == 35)
    #expect(report.byModel.first { $0.model == "explicit" }?.totalTokens == 2)
    #expect(report.byModel.first { $0.model == "negative" }?.totalTokens == 5)
}

@Test func rangesIncludeTheirCalendarStartAndExcludeOlderBuckets() async {
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    await store.ingest([
        sample(at: reference), sample(at: reference.addingTimeInterval(-2 * 86400)),
        sample(at: UsageRange.week.start(now: reference, calendar: utc())),
        sample(at: reference.addingTimeInterval(-7 * 86400)),
        sample(at: UsageRange.month.start(now: reference, calendar: utc())),
        sample(at: reference.addingTimeInterval(-30 * 86400)),
    ])
    #expect(await store.report(.today, accounts: [], now: reference).totals.requests == 1)
    #expect(await store.report(.week, accounts: [], now: reference).totals.requests == 3)
    #expect(await store.report(.month, accounts: [], now: reference).totals.requests == 5)
}

@Test func futureDatesClampOldRecordsDropAndNamesAreBounded() async {
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    await store.ingest([
        sample("future", at: reference.addingTimeInterval(100 * 86400)),
        sample("too-old", at: reference.addingTimeInterval(-31 * 86400 - 1)),
        sample(String(repeating: "x", count: 100)),
        sample(String(repeating: "x", count: 64) + "suffix"),
    ])
    let report = await store.report(.month, accounts: [], now: reference)
    #expect(report.totals.requests == 3)
    #expect(!report.byModel.contains { $0.model == "too-old" })
    #expect(report.byModel.first { $0.model == String(repeating: "x", count: 64) }?.requests == 2)
    #expect(report.byModel.allSatisfy { $0.model.count <= 64 })
}

@Test func pruningRemovesHistoryOlderThanThirtyOneDays() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let clock = StoreClock()
    let store = UsageStore(url: url, calendar: utc(), now: { clock.now() })
    await store.ingest([sample(at: reference.addingTimeInterval(-30 * 86400))])
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 1)
    clock.advance(2 * 86400)
    await store.ingest([])
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 0)
    #expect(await store.report(.month, accounts: [], now: clock.now()).trackingSince == reference)
}

@Test func databasePersistenceRoundTripAndReset() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var first: UsageStore? = UsageStore(url: url, calendar: utc(), now: { reference })
    await first?.ingest([sample("persistent", index: "fake-claude-1", total: 123)])
    let expected = await first?.report(.month, accounts: try knownAccounts(), now: reference)
    first = nil
    let reopened = UsageStore(url: url, calendar: utc(), now: { reference })
    #expect(
        await reopened.report(.month, accounts: try knownAccounts(), now: reference) == expected)
    await reopened.reset()
    let empty = await reopened.report(.month, accounts: [], now: reference)
    #expect(empty.totals == .zero)
    #expect(empty.trackingSince == nil)
    #expect(empty.isPartial)
}

@Test func corruptDatabaseIsPreservedAndRecreated() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let corrupt = Data("not a SQLite database".utf8)
    try corrupt.write(to: url)
    let store = UsageStore(url: url, calendar: utc(), now: { reference })
    #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == corrupt)
    await store.ingest([sample(total: 99)])
    #expect(await store.report(.today, accounts: [], now: reference).totals.totalTokens == 99)
    #expect(try sqliteInteger(url, sql: "PRAGMA user_version") == 1)
}

@Test func unopenableDatabaseFallsBackWithoutCrashing() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let blocker = url.deletingLastPathComponent().appendingPathComponent("not-a-directory")
    try Data("blocker".utf8).write(to: blocker)
    let store = UsageStore(
        url: blocker.appendingPathComponent("usage.sqlite"), calendar: utc(), now: { reference })
    await store.ingest([sample()])
    #expect(await store.report(.today, accounts: [], now: reference).totals.requests == 1)
}

@Test func emptyFirstIngestStartsTrackingAndPartialReportsAreExplicit() async {
    let clock = StoreClock()
    let store = UsageStore(url: nil, calendar: utc(), now: { clock.now() })
    #expect(await store.report(.month, accounts: [], now: reference).trackingSince == nil)
    await store.ingest([])
    clock.advance(3600)
    await store.ingest([])
    let report = await store.report(.today, accounts: [], now: clock.now())
    #expect(report.trackingSince == reference)
    #expect(report.isPartial)
    let start = UsageRange.today.start(now: reference, calendar: utc())
    #expect(!UsageReport(range: .today, start: start, trackingSince: start).isPartial)
    #expect(
        !UsageReport(range: .today, start: start, trackingSince: start.addingTimeInterval(-1))
            .isPartial)
    #expect(UsageReport(range: .today, start: start).isPartial)
}

@Test func legacyJsonAggregatesAreDeletedNotMigrated() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let legacy = url.deletingLastPathComponent().appendingPathComponent("usage.json")
    try Data(#"{"buckets":[{"model":"legacy","requests":1000}]}"#.utf8).write(to: legacy)
    let store = UsageStore(url: url, calendar: utc(), now: { reference })
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(await store.report(.month, accounts: [], now: reference).totals == .zero)
}

@Test func boundIdentifiersCannotChangeTheDatabaseSchema() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = UsageStore(url: url, calendar: utc(), now: { reference })
    let maliciousModel = "model'); DROP TABLE buckets; --"
    let maliciousIndex = "index' OR 1=1 --"
    await store.ingest([sample(maliciousModel, index: maliciousIndex), sample("normal")])
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.byModel.contains { $0.model == maliciousModel })
    #expect(report.byAccount.contains { $0.authIndex == maliciousIndex })
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 2)
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM pragma_table_info('buckets')") == 9)
    #expect(
        try sqliteInteger(
            url,
            sql:
                "SELECT COUNT(*) FROM pragma_table_info('buckets') WHERE name IN ('api_key','email','client_ip','body','user_agent')"
        ) == 0)
}

@Test func modelCardinalityAndHugeCounterSumsRemainBounded() async {
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    await store.ingest((0..<220).map { sample("model-\($0)", total: 10) })
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.byModel.count == 200)
    #expect(report.byModel.first { $0.model == "other" }?.requests == 21)
    #expect(report.totals.requests == 220)
    let large = UsageStore(url: nil, calendar: utc(), now: { reference })
    await large.ingest([
        sample(input: Int.max, output: Int.max), sample(input: Int.max, output: Int.max),
    ])
    #expect(await large.report(.today, accounts: [], now: reference).totals.totalTokens == Int.max)
}

@Test func reportSortingUsesTokensRequestsAndNames() async throws {
    var accounts = try knownAccounts()
    accounts[0].label = "Zed"
    accounts[1].label = "Alpha"
    let store = UsageStore(url: nil, calendar: utc(), now: { reference })
    await store.ingest([
        sample("alpha", index: accounts[0].authIndex, total: 10),
        sample("alpha", index: accounts[0].authIndex, total: 10),
        sample("zeta", index: accounts[1].authIndex, provider: "codex", total: 20),
        sample("beta", index: "config", provider: "claude", total: 20),
    ])
    let report = await store.report(.today, accounts: accounts, now: reference)
    #expect(report.byModel.map(\.model) == ["alpha", "beta", "zeta"])
    #expect(report.byAccount.map(\.label) == ["Zed", "Alpha", "Claude account · nfig"])
}

@MainActor @Test func modelPollBuildsAllAccountAttributedUsageReports() async {
    let stub = StubTransport([
        .response(200, Fixtures.data("usage-queue")), .response(200, Fixtures.data("auth-files")),
    ])
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake"), defaults: defaults,
        store: UsageStore(url: nil, calendar: utc(), now: { reference }),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) },
        now: { reference })
    model.start()
    for _ in 0..<1000 {
        if model.lastUpdated != nil { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.usageReports.count == 3)
    #expect(model.usageReports[.today]?.totals.requests == 12)
    #expect(model.usageReports[.today]?.byModel.count == 3)
    #expect(
        model.usageReports[.today]?.byAccount.map(\.label).sorted() == [
            "alice@example.com", "charlie@example.com", "dana@example.com",
        ])
    model.stop()
}

@Test func attributedHistoryFixtureDecodesAcrossAllAccountsAndFourModels() throws {
    let history = try JSONDecoder().decode(
        UsageQueueBatch.self, from: Fixtures.data("usage-history"))
    #expect(history.records.count == 30)
    #expect(Set(history.records.compactMap(\.model)).count == 4)
    let indexes = Set(history.records.compactMap(\.authIndex))
    #expect(
        indexes.isSuperset(of: [
            "fake-claude-1", "fake-claude-2", "fake-codex-1", "fake-gemini-1", "fake-disabled-1",
            "fake-config-api-key",
        ]))
    #expect(history.records.contains { $0.authIndex == nil })
}

// A separate connection exercises real SQLite locks and failures, not store internals.
private final class StoreTestConnection {
  private let handle: OpaquePointer

  init(_ url: URL) throws {
    var opened: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let opened
    else {
      if let opened { sqlite3_close_v2(opened) }
      throw StoreTestError.sqlite
    }
    handle = opened
  }

  deinit { sqlite3_close_v2(handle) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw StoreTestError.sqlite
    }
  }
}

@Test(arguments: [
  ("Asia/Kolkata", "2026-10-01T18:30:00Z"),
  ("Asia/Kathmandu", "2026-10-01T18:15:00Z"),
  ("UTC", "2026-10-02T00:00:00Z"),
])
func todayIncludesMidnightBucketButNotPreviousMinute(_ zone: String, _ edge: String) async {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  let midnight = APIDateParser.parse(edge)!
  let store = UsageStore(url: nil, calendar: calendar, now: { reference })
  await store.ingest([
    sample("previous-day", at: midnight.addingTimeInterval(-60), total: 100),
    sample("midnight", at: midnight, total: 7),
  ])
  let today = await store.report(.today, accounts: [], now: reference)
  #expect(today.start == midnight)
  #expect(today.totals.requests == 1)
  #expect(today.totals.totalTokens == 7)
  #expect(today.byModel.map(\.model) == ["midnight"])
  #expect(await store.report(.week, accounts: [], now: reference).totals.requests == 2)
}

@Test func exclusiveLockDuringOpenFallsBackWithoutCorruptingFile() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let connection = try StoreTestConnection(url)
  try connection.execute("CREATE TABLE marker(value INTEGER); INSERT INTO marker VALUES (42)")
  let original = try Data(contentsOf: url)
  try connection.execute("BEGIN EXCLUSIVE")
  let store = UsageStore(url: url, calendar: utc(), now: { reference })
  await store.ingest([sample(total: 17)])
  #expect(await store.report(.today, accounts: [], now: reference).totals.totalTokens == 17)
  #expect(try Data(contentsOf: url) == original)
  #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
  try connection.execute("ROLLBACK")
  #expect(try sqliteInteger(url, sql: "SELECT value FROM marker") == 42)
  #expect(
    try sqliteInteger(url, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'buckets'") == 0)
}

@Test func corruptionRecoveryKeepsOnlyNewestBackup() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let backup = url.appendingPathExtension("corrupt")
  for suffix in ["", "-wal", "-shm", ".old", ".older"] {
    try Data("old backup".utf8).write(to: URL(fileURLWithPath: backup.path + suffix))
  }
  let newest = Data("newest invalid SQLite contents".utf8)
  try newest.write(to: url)
  let store = UsageStore(url: url, calendar: utc(), now: { reference })
  #expect(try Data(contentsOf: backup) == newest)
  let backups = try FileManager.default.contentsOfDirectory(
    at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix(backup.lastPathComponent) }
  #expect(backups == [backup])
  await store.ingest([sample()])
  #expect(try sqliteInteger(url, sql: "SELECT SUM(requests) FROM buckets") == 1)
}

@Test func twoStoresShareWALAndAddTheirIngestedTotals() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let first = UsageStore(url: url, calendar: utc(), now: { reference })
  let second = UsageStore(url: url, calendar: utc(), now: { reference })
  async let firstChanged = first.ingest([sample("shared", index: "same", total: 11)])
  async let secondChanged = second.ingest([sample("shared", index: "same", total: 19)])
  #expect(await firstChanged)
  #expect(await secondChanged)
  let expected = UsageTotals(requests: 2, inputTokens: 20, outputTokens: 40, totalTokens: 30)
  #expect(await first.report(.today, accounts: [], now: reference).totals == expected)
  #expect(await second.report(.today, accounts: [], now: reference).totals == expected)
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 1)
  #expect(
    try sqliteInteger(
      url, sql: "SELECT COUNT(*) FROM pragma_journal_mode WHERE journal_mode = 'wal'") == 1)
}

@Test func pruningWaitsUntilOneHourAfterLastSuccessfulPrune() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let clock = StoreClock()
  let store = UsageStore(url: url, calendar: utc(), now: { clock.now() })
  await store.ingest([])
  let connection = try StoreTestConnection(url)
  // Expired history inserted externally makes the next pruning pass observable.
  try connection.execute("INSERT INTO buckets VALUES (0, '', '', 'expired', 1, 0, 0, 0, 0)")
  clock.advance(3599)
  await store.ingest([])
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets WHERE start = 0") == 1)
  clock.advance(1)
  await store.ingest([])
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets WHERE start = 0") == 0)
  try connection.execute("INSERT INTO buckets VALUES (0, '', '', 'expired', 1, 0, 0, 0, 0)")
  clock.advance(3599)
  await store.ingest([])
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets WHERE start = 0") == 1)
  clock.advance(1)
  await store.ingest([])
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets WHERE start = 0") == 0)
}

@Test func failedWriteRollsBackAndPendingRecordsRetryExactlyOnce() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let clock = StoreClock()
  let store = UsageStore(url: url, calendar: utc(), now: { clock.now() })
  let connection = try StoreTestConnection(url)
  try connection.execute(
    """
    CREATE TRIGGER reject_usage BEFORE INSERT ON buckets
    WHEN NEW.model = 'rejected' BEGIN SELECT RAISE(ABORT, 'test write failure'); END
    """)
  // The return value also signals external schema changes; inspect committed rows instead.
  await store.ingest([sample("first", total: 11), sample("rejected", total: 19)])
  #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 0)
  #expect(await store.report(.today, accounts: [], now: reference).trackingSince == nil)
  try connection.execute("DROP TRIGGER reject_usage")
  clock.advance(60)
  #expect(await store.ingest([sample("next", total: 5)]))
  let report = await store.report(.today, accounts: [], now: clock.now())
  #expect(report.totals.requests == 3)
  #expect(report.totals.totalTokens == 35)
  #expect(report.trackingSince == reference)
  #expect(await store.ingest([]) == false)
  #expect(await store.report(.today, accounts: [], now: clock.now()) == report)
}

@Test func busyWriteKeepsPendingRecordsUntilLockIsReleased() async throws {
  let url = try databaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = UsageStore(url: url, calendar: utc(), now: { reference })
  let connection = try StoreTestConnection(url)
  try connection.execute("BEGIN IMMEDIATE")
  #expect(await store.ingest([sample(total: 23)]) == false)
  #expect(await store.report(.today, accounts: [], now: reference).trackingSince == nil)
  try connection.execute("ROLLBACK")
  #expect(await store.ingest([]))
  let report = await store.report(.today, accounts: [], now: reference)
  #expect(report.totals.requests == 1)
  #expect(report.totals.totalTokens == 23)
  #expect(report.trackingSince == reference)
  await store.ingest([])
  #expect(await store.report(.today, accounts: [], now: reference) == report)
}

@Test func unknownRoutingIndexesUseProviderAndLastFourCharacters() async {
  let store = UsageStore(url: nil, calendar: utc(), now: { reference })
  await store.ingest([
    sample(index: "missing-1234", provider: "codex"),
    sample(index: "missing-5678", provider: ""),
    sample(index: "", provider: "claude"),
  ])
  let report = await store.report(.today, accounts: [], now: reference)
  #expect(
    report.byAccount.first { $0.authIndex == "missing-1234" }?.label == "Codex account · 1234")
  #expect(
    report.byAccount.first { $0.authIndex == "missing-5678" }?.label == "Unknown account · 5678")
  let unattributed = report.byAccount.first { $0.authIndex == nil }
  #expect(unattributed?.label == "Unattributed")
  #expect(unattributed?.provider.isUnknown == true)
}

@Test func pendingAggregatesPreserveMoreThanFiveThousandRecordsAcrossFailures() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = UsageStore(url: url, calendar: utc(), now: { reference })
    let connection = try StoreTestConnection(url)
    try connection.execute("BEGIN IMMEDIATE")
    #expect(await store.ingest(Array(repeating: sample("first", failed: true), count: 3_100)) == false)
    #expect(await store.ingest(Array(repeating: sample("second", total: 7), count: 3_200)) == false)
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 0)
    try connection.execute("ROLLBACK")
    #expect(await store.ingest([]))
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.totals == UsageTotals(
        requests: 6_300, failed: 3_100, inputTokens: 63_000,
        outputTokens: 126_000, totalTokens: 3_100 * 35 + 3_200 * 7))
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 2)
    #expect(await store.ingest([]) == false)
    #expect(await store.report(.today, accounts: [], now: reference) == report)
}

@Test(arguments: [false, true])
func pendingOverflowFoldsOldestKeysWithoutLosingCounters(uniqueAccounts: Bool) async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = UsageStore(url: url, calendar: utc(), now: { reference })
    let connection = try StoreTestConnection(url)
    try connection.execute("BEGIN IMMEDIATE")
    let records = (0..<50_200).map { index in
        sample(
            "model-\(index % 200)",
            at: reference.addingTimeInterval(index < 200 ? -900 : 0),
            index: uniqueAccounts ? "account-\(index)" : String(format: "account-%03d", index / 200),
            failed: true, total: 7)
    }
    #expect(await store.ingest(records) == false)
    try connection.execute("ROLLBACK")
    #expect(await store.ingest([]))
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.totals == UsageTotals(
        requests: 50_200, failed: 50_200, inputTokens: 502_000,
        outputTokens: 1_004_000, totalTokens: 351_400))
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") <= 50_000)
    let oldest = Int64(floor(reference.addingTimeInterval(-900).timeIntervalSince1970 / 900) * 900)
    #expect(try sqliteInteger(url, sql: "SELECT SUM(requests) FROM buckets WHERE start = \(oldest) AND model = 'other'") >= 200)
    #expect(await store.ingest([]) == false)
    #expect(await store.report(.today, accounts: [], now: reference) == report)
}

@Test func failedInitialIngestRetainsAllAggregatedRecords() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let seed = UsageStore(url: url, calendar: utc(), now: { reference })
    await seed.ingest([])
    let connection = try StoreTestConnection(url)
    try connection.execute(
        "CREATE TRIGGER reject_initial BEFORE INSERT ON buckets BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    let store = UsageStore(
        url: url, calendar: utc(), now: { reference },
        initialRecords: Array(repeating: sample(total: 7), count: 6_100))
    #expect(try sqliteInteger(url, sql: "SELECT COUNT(*) FROM buckets") == 0)
    try connection.execute("DROP TRIGGER reject_initial")
    #expect(await store.ingest([]))
    let report = await store.report(.today, accounts: [], now: reference)
    #expect(report.totals.requests == 6_100)
    #expect(report.totals.totalTokens == 42_700)
    #expect(await store.ingest([]) == false)
    #expect(await store.report(.today, accounts: [], now: reference) == report)
}
