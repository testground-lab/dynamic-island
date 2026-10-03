import Foundation
import SQLite3
import Testing

@testable import IslandCore

private enum RetentionTestError: Error { case sqlite }

private func retentionCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

private func retentionDatabaseURL() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("retention-tests").appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("usage.sqlite")
}

private func retentionBucketStart(_ date: Date) -> Int64 {
  Int64(floor(date.timeIntervalSince1970 / 900) * 900)
}

private final class RetentionConnection {
  private let handle: OpaquePointer

  init(_ url: URL, create: Bool = false) throws {
    var opened: OpaquePointer?
    // Read-write even for counting: a read-only connection can't open a WAL database
    // whose -shm file doesn't exist yet (e.g. a fresh copy of the real one).
    let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE
    guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
      if let opened { sqlite3_close_v2(opened) }
      throw RetentionTestError.sqlite
    }
    handle = opened
  }

  deinit { sqlite3_close_v2(handle) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw RetentionTestError.sqlite
    }
  }

  func count(_ sql: String) throws -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RetentionTestError.sqlite
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw RetentionTestError.sqlite }
    return sqlite3_column_int64(statement, 0)
  }
}

// Write the existing v1 schema directly, with no new-store ingest acceptance filtering.
// The connection closes before the store opens, modeling an existing database file.
private func seedRetentionDatabase(_ url: URL, now: Date, ages: [Int]) throws {
  let connection = try RetentionConnection(url, create: true)
  try connection.execute("""
    CREATE TABLE buckets (
      start INTEGER NOT NULL, auth_index TEXT NOT NULL, provider TEXT NOT NULL,
      model TEXT NOT NULL, requests INTEGER NOT NULL, failed INTEGER NOT NULL,
      input INTEGER NOT NULL, output INTEGER NOT NULL, total INTEGER NOT NULL,
      PRIMARY KEY(start, auth_index, model)
    );
    CREATE TABLE meta (key TEXT PRIMARY KEY, value REAL);
    PRAGMA user_version = 1;
    """)
  for age in ages {
    let start = retentionBucketStart(now.addingTimeInterval(-Double(age) * 86400))
    try connection.execute("""
      INSERT INTO buckets VALUES (
        \(start), '', 'claude', 'age-\(age)', 1, 0, 10, 20, 30
      )
      """)
  }
}

@Test func pruningKeepsAllBucketsWithinOneHundredEightyThreeDays() async throws {
  let url = try retentionDatabaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let now = Fixtures.referenceNow
  try seedRetentionDatabase(url, now: now, ages: [1, 32, 100, 182, 184])
  let store = UsageStore(url: url, calendar: retentionCalendar(), now: { now })
  let connection = try RetentionConnection(url)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets") == 5)
  await store.ingest([])
  #expect(try connection.count("SELECT COUNT(*) FROM buckets") == 4)
  for age in [1, 32, 100, 182] {
    #expect(try connection.count("SELECT COUNT(*) FROM buckets WHERE model = 'age-\(age)'") == 1)
  }
  #expect(try connection.count("SELECT COUNT(*) FROM buckets WHERE model = 'age-184'") == 0)
}

@Test func existingDatabaseKeepsFortyAndNinetyDayHistoryInHalfYearReports() async throws {
  let url = try retentionDatabaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let now = Fixtures.referenceNow
  try seedRetentionDatabase(url, now: now, ages: [40, 90])
  let store = UsageStore(url: url, calendar: retentionCalendar(), now: { now })
  #expect(store.initialReports[.halfYear]?.totals.requests == 2)
  await store.ingest([])
  let connection = try RetentionConnection(url)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets") == 2)
  #expect(try connection.count("PRAGMA user_version") == 1)
  #expect(await store.report(.halfYear, accounts: [], now: now).totals.requests == 2)
  #expect(await store.report(.month, accounts: [], now: now).totals.requests == 0)
  let series = await store.seriesAll(now: now)
  #expect(series[.halfYear]?.points.reduce(0) { $0 + $1.totalTokens } == 60)
  for range in UsageRange.allCases {
    #expect(series[range] == (await store.series(range, now: now)))
  }
}

// DI_DB_COPY names a database to check, e.g. a copy of a real one. The test copies it
// (with any -wal/-shm) into a temporary folder and prunes only that copy; it refuses the
// app's live database outright.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DI_DB_COPY"] != nil))
func realDatabaseCopyPrunesOnlyBucketsOlderThanRetention() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["DI_DB_COPY"])
  let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  try #require(!source.path.contains("Application Support/DynamicIsland"))
  let url = try retentionDatabaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  for suffix in ["", "-wal", "-shm"] {
    let file = URL(fileURLWithPath: source.path + suffix)
    guard FileManager.default.fileExists(atPath: file.path) else { continue }
    try FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: url.path + suffix))
  }
  let now = Date()
  let cutoff = retentionBucketStart(now.addingTimeInterval(-UsageStore.retention))
  let connection = try RetentionConnection(url)
  let before = try connection.count("SELECT COUNT(*) FROM buckets")
  let expired = try connection.count("SELECT COUNT(*) FROM buckets WHERE start < \(cutoff)")
  let store = UsageStore(url: url, now: { now })
  await store.ingest([])
  let after = try connection.count("SELECT COUNT(*) FROM buckets")
  print("Retention copy: before=\(before), expired=\(expired), after=\(after), cutoff=\(cutoff)")
  #expect(after == before - expired)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets WHERE start < \(cutoff)") == 0)
}

@Test func pruningUsesStrictRoundedBucketCutoff() async throws {
  let url = try retentionDatabaseURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let now = Fixtures.referenceNow.addingTimeInterval(437)
  let cutoff = retentionBucketStart(now.addingTimeInterval(-UsageStore.retention))
  try seedRetentionDatabase(url, now: now, ages: [])
  do {
    let writer = try RetentionConnection(url, create: true)
    for start in [cutoff - 900, cutoff, cutoff + 900] {
      try writer.execute("""
        INSERT INTO buckets VALUES (\(start), '', 'claude', 'model', 1, 0, 10, 20, 30)
        """)
    }
  }
  let store = UsageStore(url: url, calendar: retentionCalendar(), now: { now })
  await store.ingest([])
  let connection = try RetentionConnection(url)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets") == 2)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets WHERE start = \(cutoff)") == 1)
  #expect(try connection.count("SELECT COUNT(*) FROM buckets WHERE start < \(cutoff)") == 0)
}

/// The 6m range must never reach past what is kept, or its first week would be partly pruned.
@Test(arguments: [1, 2], ["UTC", "America/New_York", "Australia/Lord_Howe", "Pacific/Kiritimati"])
func halfYearRangeStaysInsideRetention(_ firstWeekday: Int, _ zone: String) throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: zone))
  calendar.firstWeekday = firstWeekday
  var day = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
  for _ in 0..<366 {
    let lastMinute = try #require(calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day))
    for now in [day, lastMinute] {
      let start = UsageRange.halfYear.start(now: now, calendar: calendar)
      #expect(start >= now.addingTimeInterval(-UsageStore.retention))
    }
    day = try #require(calendar.date(byAdding: .day, value: 1, to: day))
  }
}
