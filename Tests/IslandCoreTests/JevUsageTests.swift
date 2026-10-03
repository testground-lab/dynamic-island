import Foundation
import Darwin
import Testing
import Synchronization
import Observation

@testable import IslandCore

private func jevCalendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func jevDate(_ raw: String) -> Date { APIDateParser.parse(raw)! }
private let jevNow = jevDate("2026-10-03T15:00:00Z")
private let jevLine = "{\"ts\":\"2026-10-03T05:12:18.123Z\",\"model\":\"jev-latest\",\"input_tokens\":123,\"output_tokens\":4,\"latency_ms\":850,\"ok\":true,\"error\":null}"

private func jevCall(_ date: Date, input: Int = 100, output: Int = 3,
                     ok: Bool = true, error: String? = nil) -> JevCall {
    JevCall(timestamp: date, model: "jev", inputTokens: input, outputTokens: output,
            ok: ok, error: error)
}

private func jevTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func jevParsesGoodLinesAndUnknownFields() {
    let parsed = JevLog.parse(Data((jevLine + "\n" +
        "{\"ts\":\"2026-10-03T05:12:18Z\",\"unknown\":42}\n").utf8))
    #expect(parsed.skippedLines == 0)
    #expect(parsed.calls.count == 2)
    #expect(parsed.calls[0].model == "jev")
    #expect(parsed.calls[0].ok)
    #expect(parsed.calls[1].inputTokens == 123)
    #expect(parsed.calls[1].outputTokens == 4)
    #expect(parsed.calls[1].totalTokens == 127)
    #expect(parsed.calls[1].latencyMs == 850)
    #expect(parsed.calls[1].error == nil)
}

@Test func jevIgnoresBlanksAndCountsInvalidLines() {
    let invalid = ["{broken", "{\"ts\":", "[]", "42", "{}", "{\"ts\":\"bad\"}"]
    let parsed = JevLog.parse(Data((" \t\r\n\n" + jevLine + "\r\n" + invalid.joined(separator: "\n")).utf8))
    #expect(parsed.calls.count == 1)
    #expect(parsed.skippedLines == invalid.count)
    #expect(JevLog.parse(Data()) == JevLogParse(calls: [], skippedLines: 0))
}

@Test func jevInvalidUTF8OnlyDropsOneLine() {
    var bytes = Data((jevLine + "\n").utf8)
    bytes.append(contentsOf: [0xff, 0xfe, 10])
    bytes.append(Data(jevLine.utf8))
    let parsed = JevLog.parse(bytes)
    #expect(parsed.calls.count == 2)
    #expect(parsed.skippedLines == 1)
}

@Test func jevNumericAndBooleanWireTypes() {
    let line = "{\"ts\":\"2026-10-03T00:00:00Z\",\"model\":\"\",\"input_tokens\":-5,\"output_tokens\":4.0,\"latency_ms\":-1,\"ok\":1}"
    let call = JevLog.parse(Data(line.utf8)).calls[0]
    #expect(call.model == "jev")
    #expect(call.inputTokens == 0)
    #expect(call.outputTokens == 4)
    #expect(call.latencyMs == 0)
    #expect(call.ok)
    let nonintegral = "{\"ts\":\"2026-10-03T00:00:00Z\",\"input_tokens\":2.5,\"output_tokens\":true,\"latency_ms\":\"20\",\"error\":23}"
    let other = JevLog.parse(Data(nonintegral.utf8)).calls[0]
    #expect(other.totalTokens == 0)
    #expect(other.latencyMs == nil)
    #expect(other.error == nil)
    #expect(other.ok)
}

@Test(arguments: ["timeout", "http_502", "network"])
func jevInfersFailureWhenOKMissing(_ error: String) {
    let line = "{\"ts\":\"2026-10-03T00:00:00Z\",\"error\":\"\(error)\"}"
    let call = JevLog.parse(Data(line.utf8)).calls[0]
    #expect(!call.ok)
    #expect(call.error == error)
    #expect(call.totalTokens == 0)
    let explicit = line.dropLast() + ",\"ok\":true}"
    #expect(JevLog.parse(Data(explicit.utf8)).calls[0].ok)
}

@Test func jevSortIsStable() {
    let lines = ["b", "a", "c"].map {
        "{\"ts\":\"2026-10-03T00:00:00Z\",\"model\":\"\($0)\"}"
    }
    #expect(JevLog.parse(Data(lines.joined(separator: "\n").utf8)).calls.map(\.model) == ["b", "a", "c"])
}

@Test func jevReadsMissingDirectoryAndGoodFile() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(JevLog.read(directory.appendingPathComponent("missing")) == .missing)
    #expect(JevLog.read(directory.appendingPathComponent("missing/usage.jsonl")) == .missing)
    #expect(JevLog.read(directory) == .unreadable("Not a regular file"))
    let file = directory.appendingPathComponent("usage-test.jsonl")
    try Data(jevLine.utf8).write(to: file)
    #expect(JevLog.read(file) == .loaded(JevLog.parse(Data(jevLine.utf8))))
}

@Test func jevReadPermissionDenied() throws {
    guard geteuid() != 0 else { return }
    let directory = try jevTemporaryDirectory()
    let file = directory.appendingPathComponent("usage-test.jsonl")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try Data(jevLine.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    #expect(JevLog.read(file) == .unreadable("Permission denied"))
}

@Test func jevRejectsOversizeFile() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-test.jsonl")
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
    try handle.close()
    #expect(JevLog.read(file) == .unreadable("Too large to read (65 MB)"))
}

@Test func jevScanMissingEmptyAndMarkerDirectories() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(JevLog.scan(directory: directory.appendingPathComponent("missing"), previous: [:],
                        modifiedSince: .distantPast).read == .missing)
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).read == .missing)
    try Data(jevLine.utf8).write(to: directory.appendingPathComponent(".last-prune"))
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).read == .missing)
}

@Test func jevScanMergesSessionsWithStableTimestampOrder() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = "{\"ts\":\"2026-10-03T00:00:00Z\",\"model\":\"first\"}"
    let second = "{\"ts\":\"2026-10-03T00:00:00Z\",\"model\":\"second\"}"
    try Data((jevLine + "\n" + first + "\ninvalid").utf8)
        .write(to: directory.appendingPathComponent("usage-a.jsonl"))
    try Data(second.utf8).write(to: directory.appendingPathComponent("usage-b.jsonl"))
    let scan = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    let parsed = try #require({ if case .loaded(let parsed) = scan.read { return parsed }; return nil }())
    #expect(parsed.calls.map(\.model) == ["first", "second", "jev-latest"])
    #expect(parsed.skippedLines == 1)
    #expect(scan.files.count == 2)
}

@Test func jevScanPicksUpWholeRewritesPartsAndDeletions() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-abc.jsonl")
    try Data(jevLine.utf8).write(to: file)
    let initial = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    try Data((jevLine + "\n" + jevLine).utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: jevNow], ofItemAtPath: file.path)
    let rewritten = JevLog.scan(directory: directory, previous: initial.files, modifiedSince: .distantPast)
    #expect(rewritten.files["usage-abc.jsonl"]?.calls.count == 2)
    let replacement = (jevLine + "\n" + jevLine).replacingOccurrences(of: "123,", with: "321,")
    usleep(1_000)
    try Data(replacement.utf8).write(to: file)
    let modified = try #require(rewritten.files["usage-abc.jsonl"]?.signature.modified)
    try FileManager.default.setAttributes([.modificationDate: modified],
                                          ofItemAtPath: file.path)
    let sameSize = JevLog.scan(directory: directory, previous: rewritten.files, modifiedSince: .distantPast)
    #expect(sameSize.files["usage-abc.jsonl"]?.calls.map(\.inputTokens) == [321, 321])
    let before = try #require(rewritten.files["usage-abc.jsonl"]?.signature)
    let after = try #require(sameSize.files["usage-abc.jsonl"]?.signature)
    #expect(after.inode == before.inode)
    #expect(after.size == before.size)
    #expect(after.modifiedNanoseconds == before.modifiedNanoseconds)
    #expect(after.changedNanoseconds != before.changedNanoseconds)
    let part = directory.appendingPathComponent("usage-abc.1.jsonl")
    try Data(jevLine.utf8).write(to: part)
    let added = JevLog.scan(directory: directory, previous: sameSize.files, modifiedSince: .distantPast)
    #expect(added.files.count == 2)
    try FileManager.default.removeItem(at: file)
    let deleted = JevLog.scan(directory: directory, previous: added.files, modifiedSince: .distantPast)
    #expect(deleted.warning == nil)
    #expect(deleted.files.keys.sorted() == ["usage-abc.1.jsonl"])
    #expect(deleted.read == .loaded(JevLogParse(calls: JevLog.parse(Data(jevLine.utf8)).calls, skippedLines: 0)))
}

@Test func jevScanReusesMatchingCachedParse() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "usage-abc.jsonl"
    try Data(jevLine.utf8).write(to: directory.appendingPathComponent(name))
    var previous = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).files
    let cached = jevCall(jevNow, input: 987)
    previous[name]?.calls = [cached]
    previous[name]?.skippedLines = 2
    let scan = JevLog.scan(directory: directory, previous: previous, modifiedSince: .distantPast)
    #expect(scan.read == .loaded(JevLogParse(calls: [cached], skippedLines: 2)))
    #expect(scan.files == previous)
}

@Test func jevScanIgnoresOldFilesAndDropsTheirCache() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-old.jsonl")
    try Data(jevLine.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: jevNow.addingTimeInterval(-1)], ofItemAtPath: file.path)
    let initial = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    let scan = JevLog.scan(directory: directory, previous: initial.files, modifiedSince: jevNow)
    #expect(scan.read == .loaded(JevLogParse(calls: [], skippedLines: 0)))
    #expect(scan.latestOutsideWindow == jevNow.addingTimeInterval(-1))
    #expect(scan.files.isEmpty)
    try FileManager.default.setAttributes([.modificationDate: jevNow], ofItemAtPath: file.path)
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: jevNow).files.count == 1)
}

@Test func jevScanSkipsUnreadableFilesAndReportsAllUnreadable() throws {
    guard geteuid() != 0 else { return }
    let directory = try jevTemporaryDirectory()
    let bad = directory.appendingPathComponent("usage-a.jsonl")
    let good = directory.appendingPathComponent("usage-b.jsonl")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try Data(jevLine.utf8).write(to: bad)
    try Data(jevLine.utf8).write(to: good)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
    let scan = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    #expect(scan.files.keys.sorted() == ["usage-b.jsonl"])
    #expect(scan.read == JevLog.read(good))
    #expect(scan.warning == "1 log file couldn't be read (Permission denied); totals are incomplete.")
    try FileManager.default.removeItem(at: good)
    let failed = JevLog.scan(directory: directory, previous: scan.files, modifiedSince: .distantPast)
    #expect(failed.read == .unreadable("Permission denied"))
    #expect(failed.files.isEmpty)
}

@Test func jevScanReportsUnreadableDirectory() throws {
    guard geteuid() != 0 else { return }
    let directory = try jevTemporaryDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).read
        == .unreadable("Permission denied"))
}

@Test func jevScanReportsUnrecognisableLines() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("broken\n{}\n".utf8).write(to: directory.appendingPathComponent("usage-abc.jsonl"))
    let scan = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    #expect(scan.read == .unreadable("No recognisable lines (2 skipped)"))
    #expect(JevLog.scan(directory: directory, previous: scan.files, modifiedSince: .distantPast) == scan)
}

@Test func jevScanIgnoresOtherFilesDotfilesAndFolders() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["other.jsonl", ".last-prune", "usage-x.txt", ".usage.jsonl", "usage.jsonl.bak"] {
        try Data(jevLine.utf8).write(to: directory.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("usage-folder.jsonl"),
                                             withIntermediateDirectories: false)
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).read == .missing)
    for name in ["usage-a.jsonl", "usage-a.1.jsonl"] {
        try Data(jevLine.utf8).write(to: directory.appendingPathComponent(name))
    }
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
        .files.keys.sorted() == ["usage-a.1.jsonl", "usage-a.jsonl"])
    #expect(JevLog.scan(directory: directory.appendingPathComponent("usage-x.txt"), previous: [:],
                        modifiedSince: .distantPast).read == .unreadable("Not a folder"))
}

@Test func jevScanCapsCombinedCachedAndReadBytes() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var previous: [String: JevLogFile] = [:]
    for name in ["usage-a.jsonl", "usage-b.jsonl"] {
        let file = directory.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 33 * 1024 * 1024)
        try handle.close()
        var attributes = stat()
        #expect(stat(file.path, &attributes) == 0)
        previous[name] = JevLogFile(signature: .init(
            inode: UInt64(attributes.st_ino), size: UInt64(attributes.st_size),
            modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(attributes.st_mtimespec.tv_nsec),
            changedNanoseconds: Int64(attributes.st_ctimespec.tv_sec) * 1_000_000_000
                + Int64(attributes.st_ctimespec.tv_nsec)),
            calls: [jevCall(jevNow)], skippedLines: 0)
    }
    #expect(JevLog.scan(directory: directory, previous: previous, modifiedSince: .distantPast).read
        == .unreadable("Too large to read (66 MB)"))
    // One cached 33 MB file plus a freshly parsed file also counts toward the same cap.
    previous.removeValue(forKey: "usage-b.jsonl")
    #expect(JevLog.scan(directory: directory, previous: previous, modifiedSince: .distantPast).read
        == .unreadable("Too large to read (66 MB)"))
}

@Test func jevScanSkipsOversizeSessionWhileOthersLoad() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let large = directory.appendingPathComponent("usage-a.jsonl")
    #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
    try handle.close()
    #expect(JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast).read
        == .unreadable("Too large to read (65 MB)"))
    try Data(jevLine.utf8).write(to: directory.appendingPathComponent("usage-b.jsonl"))
    let scan = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    #expect(scan.files.keys.sorted() == ["usage-b.jsonl"])
    #expect(scan.read == .loaded(JevLog.parse(Data(jevLine.utf8))))
    #expect(scan.warning == "1 log file couldn't be read (Too large to read (65 MB)); totals are incomplete.")
}

@Test func jevSpendOnlyChargesInput() {
    #expect(JevPricing.estimatedSpendUSD(inputTokens: 1_000_000) == 0.042)
    #expect(JevPricing.estimatedSpendUSD(inputTokens: -1) == 0)
    let report = JevUsage.report([jevCall(jevNow, input: 1_000_000, output: 999_999)],
        range: .today, now: jevNow, calendar: jevCalendar())
    #expect(report.totals.estimatedSpendUSD == 0.042)
    #expect(jevCall(jevNow, input: Int.max, output: 1).totalTokens == Int.max)
}

@Test(arguments: [(Double.nan, "$0.00"), (-1, "$0.00"), (0, "$0.00"),
    (0.00001, "<$0.0001"), (0.0001, "$0.0001"), (0.0005, "$0.0005"),
    (0.0012, "$0.0012"), (0.005, "$0.005"), (0.0123, "$0.01"), (0.5, "$0.50"),
    (0.04213, "$0.04"), (0.1669, "$0.17"),
    (1.23, "$1.23"), (1234.5, "$1234.50")])
func jevFormatsSpend(_ pair: (Double, String)) {
    #expect(JevPricing.formatted(usd: pair.0) == pair.1)
}

@Test func jevFiltersWindowAndCountsFailures() {
    let calendar = jevCalendar()
    let start = calendar.startOfDay(for: jevNow)
    let calls = [jevCall(start.addingTimeInterval(-1)), jevCall(start),
        jevCall(start.addingTimeInterval(86400)), jevCall(start.addingTimeInterval(90000))]
        + ["timeout", "http_502", "network"].map { jevCall(jevNow, input: 0, output: 0, ok: false, error: $0) }
        + [jevCall(jevNow, input: 0, output: 0, ok: false)]
    let report = JevUsage.report(calls, range: .today, now: jevNow, calendar: calendar)
    #expect(report.totals.requests == 5)
    #expect(report.totals.failed == 4)
    #expect(report.totals.failuresByError == ["timeout": 1, "http_502": 1, "network": 1, "unknown": 1])
    #expect(report.totals.totalTokens == 103)
    #expect(report.series.points.reduce(0) { $0 + $1.byProvider.reduce(0) { $0 + $1.requests } } == 5)
    #expect(report.series.points.allSatisfy { $0.recorded && !$0.partial })
}

@Test func jevTodayBinsLocalHours() {
    let calendar = jevCalendar("Asia/Kolkata")
    let report = JevUsage.report([jevCall(jevDate("2026-10-03T04:00:00Z"))],
        range: .today, now: jevNow, calendar: calendar)
    #expect(report.series.points.count == 24)
    #expect(report.series.points[9].totalTokens == 103)
    #expect(calendar.component(.hour, from: report.series.points[9].start) == 9)
}

@Test(arguments: [UsageRange.week, .month])
func jevDailyBinsLocalMidnights(_ range: UsageRange) {
    let calendar = jevCalendar("America/New_York")
    let calls = [jevCall(jevDate("2026-10-03T03:30:00Z")), jevCall(jevDate("2026-10-03T04:30:00Z"))]
    let report = JevUsage.report(calls, range: range, now: jevNow, calendar: calendar)
    #expect(report.series.points.count == (range == .week ? 7 : 30))
    #expect(report.series.points.suffix(2).map(\.totalTokens) == [103, 103])
    #expect(report.series.points.allSatisfy { calendar.component(.hour, from: $0.start) == 0 })
    let old = jevCall(report.start.addingTimeInterval(-1))
    #expect(JevUsage.report(calls + [old], range: range, now: jevNow, calendar: calendar).totals.requests == 2)
}

@Test func jevDSTSpringAndRepeatedFallHours() {
    let calendar = jevCalendar("America/New_York")
    let spring = JevUsage.report([], range: .today, now: jevDate("2026-03-08T12:00:00Z"), calendar: calendar)
    #expect(spring.series.points.count == 23)
    let fall = JevUsage.report([
        jevCall(jevDate("2026-11-01T05:20:00Z"), input: 10, output: 0),
        jevCall(jevDate("2026-11-01T06:20:00Z"), input: 20, output: 0)],
        range: .today, now: jevDate("2026-11-01T12:00:00Z"), calendar: calendar)
    #expect(fall.series.points.count == 25)
    let repeated = fall.series.points.filter { calendar.component(.hour, from: $0.start) == 1 }
    #expect(repeated.map(\.totalTokens) == [10, 20])
}

@Test(arguments: [
    ("2026-04-05T12:00:00Z", "2026-04-04T15:15:00Z", 24.5, 5400.0),
    ("2026-10-04T12:00:00Z", "2026-10-03T15:45:00Z", 23.5, 5400.0),
])
func jevHalfHourDSTBinsCalendarHours(_ fixture: (String, String, Double, Double)) {
    let calendar = jevCalendar("Australia/Lord_Howe")
    let now = jevDate(fixture.0)
    let report = JevUsage.report([jevCall(jevDate(fixture.1))],
        range: .today, now: now, calendar: calendar)
    let point = report.series.points.first { $0.totalTokens > 0 }!
    #expect(calendar.component(.hour, from: point.start) == 1)
    #expect(calendar.component(.minute, from: point.start) == 0)
    #expect(point.end.timeIntervalSince(point.start) == fixture.3)
    let duration = report.series.points.last!.end.timeIntervalSince(report.series.points.first!.start)
    #expect(duration == fixture.2 * 3600)
    #expect(report.series.points.allSatisfy { $0.recorded && !$0.partial })
}

@MainActor @Test func jevMonitorReadsSessionsRewritesDeletes() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-test.jsonl")
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(), now: { jevNow })
    #expect(monitor.state(for: .today) == .loading)
    await monitor.reload()
    #expect(monitor.state(for: .today) == .missing)
    try Data(jevLine.utf8).write(to: file)
    await monitor.reload()
    #expect(monitor.reports[.today]?.totals.requests == 1)
    #expect(monitor.state(for: .today) == .data(monitor.reports[.today]!))
    let session = directory.appendingPathComponent("usage-other.jsonl")
    try Data(jevLine.utf8).write(to: session)
    await monitor.reload()
    #expect(monitor.reports[.today]?.totals.requests == 2)
    try Data((jevLine + "\n" + jevLine).utf8).write(to: file)
    await monitor.reload()
    #expect(monitor.reports[.today]?.totals.requests == 3)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: session)
    await monitor.reload()
    #expect(monitor.log == .missing)
    #expect(monitor.lastCall == nil)
    #expect(monitor.reports.isEmpty)
}

@MainActor @Test func jevMonitorEmptyUnreadableAndNilStates() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let wrongPath = directory.appendingPathComponent("not-a-folder")
    try Data().write(to: wrongPath)
    let unreadable = JevUsageMonitor(directory: wrongPath)
    await unreadable.reload()
    #expect(unreadable.state(for: .today) == .unreadable("Not a folder"))
    let missing = JevUsageMonitor(directory: nil)
    await missing.reload()
    #expect(missing.state(for: .today) == .missing)
    let file = directory.appendingPathComponent("usage-test.jsonl")
    try Data().write(to: file)
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(), now: { jevNow })
    await monitor.reload()
    #expect(monitor.state(for: .today) == .empty(lastCall: nil))
    try Data("{\"ts\":\"2026-10-02T00:00:00Z\"}".utf8).write(to: file)
    await monitor.reload()
    #expect(monitor.state(for: .today) == .empty(lastCall: jevDate("2026-10-02T00:00:00Z")))
}

@MainActor @Test func jevMonitorRecomputesAtHourAndDayBoundaries() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-test.jsonl")
    try Data(jevLine.utf8).write(to: file)
    let clock = Mutex(jevDate("2026-10-03T05:30:00Z"))
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(), now: { clock.withLock { $0 } })
    await monitor.reload()
    let initial = monitor.reports[.today]
    await monitor.reload()
    #expect(monitor.reports[.today] == initial)
    clock.withLock { $0 = jevDate("2026-10-03T06:30:00Z") }
    await monitor.reload()
    #expect(monitor.reports[.today]?.series.points[6].future == false)
    clock.withLock { $0 = jevDate("2026-10-04T00:30:00Z") }
    async let first: Void = monitor.reload()
    async let second: Void = monitor.reload()
    _ = await (first, second)
    #expect(monitor.reports[.today]?.totals.requests == 0)
    #expect(monitor.reports[.week]?.totals.requests == 1)
}

@MainActor @Test func jevMonitorDoesNotInvalidateUnchangedObservableState() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-abc.jsonl")
    let clock = Mutex(jevNow)
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(),
                                  now: { clock.withLock { $0 } })
    for contents in [nil, "broken", jevLine] as [String?] {
        if let contents { try Data(contents.utf8).write(to: file) }
        await monitor.reload()
        let changes = Mutex(0)
        withObservationTracking {
            _ = monitor.log
            _ = monitor.reports
            _ = monitor.lastCall
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        await monitor.reload()
        #expect(changes.withLock { $0 } == 0)
        if contents == jevLine {
            clock.withLock { $0 = jevNow.addingTimeInterval(3600) }
            await monitor.reload()
            #expect(changes.withLock { $0 } == 1)
        }
    }
}

@MainActor @Test func jevMonitorUsesNewestCallAcrossSessions() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(jevLine.utf8).write(to: directory.appendingPathComponent("usage-z.jsonl"))
    let latest = "{\"ts\":\"2026-10-03T14:00:00Z\"}"
    try Data(latest.utf8).write(to: directory.appendingPathComponent("usage-a.jsonl"))
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(), now: { jevNow })
    await monitor.reload()
    #expect(monitor.lastCall == jevDate("2026-10-03T14:00:00Z"))
    #expect(monitor.reports[.today]?.totals.requests == 2)
}

@MainActor @Test func jevDemoIsDeterministicAndNeverPolls() async {
    let monitor = JevUsageMonitor.demo(now: jevNow, calendar: jevCalendar())
    let duplicate = JevUsageMonitor.demo(now: jevNow, calendar: jevCalendar())
    #expect(monitor.reports == duplicate.reports)
    for range in UsageRange.allCases {
        #expect(monitor.reports[range]!.totals.requests > 0)
        let totals = monitor.reports[range]!.totals
        let successful = totals.requests - totals.failed
        #expect(totals.outputTokens >= successful * 100)
        #expect(totals.outputTokens <= successful * 300)
        #expect(monitor.state(for: range) == .data(monitor.reports[range]!))
    }
    let original = monitor.reports
    monitor.start()
    monitor.start()
    await monitor.reload()
    monitor.stop()
    #expect(monitor.reports == original)
    #expect(monitor.lastCall! <= jevNow)
}

@MainActor @Test func jevMonitorPollingStopsAndRefreshes() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage-test.jsonl")
    let monitor = JevUsageMonitor(directory: directory, calendar: jevCalendar(), now: { jevNow },
                                  pollInterval: .milliseconds(10))
    monitor.start()
    monitor.start()
    for _ in 0..<200 where monitor.log == .loading {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(monitor.log == .missing)
    try Data(jevLine.utf8).write(to: file)
    for _ in 0..<200 where monitor.log != .loaded {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(monitor.reports[.today]?.totals.requests == 1)
    monitor.stop()
    await monitor.reload()
    try Data((jevLine + "\n" + jevLine).utf8).write(to: file)
    try await Task.sleep(for: .milliseconds(30))
    #expect(monitor.reports[.today]?.totals.requests == 1)
    monitor.refresh()
    for _ in 0..<200 where monitor.reports[.today]?.totals.requests != 2 {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(monitor.reports[.today]?.totals.requests == 2)
}

@Test func jevExplicitFailedNullErrorAndSaturatingTotals() {
    let line = "{\"ts\":\"2026-10-03T00:00:00Z\",\"ok\":false,\"error\":null}"
    let call = JevLog.parse(Data(line.utf8)).calls[0]
    #expect(!call.ok)
    #expect(call.error == nil)
    let report = JevUsage.report([call, jevCall(jevNow, input: Int.max, output: Int.max),
        jevCall(jevNow, input: 1, output: 1)], range: .today, now: jevNow, calendar: jevCalendar())
    #expect(report.totals.failuresByError == ["unknown": 1])
    #expect(report.totals.inputTokens == Int.max)
    #expect(report.totals.outputTokens == Int.max)
    #expect(report.totals.totalTokens == Int.max)
    #expect(report.series.points[15].totalTokens == Int.max)
}

@Test(arguments: [
    ("2026-04-05T12:00:00Z", "2026-04-04T15:00:00Z", 24.5),
    ("2026-10-04T12:00:00Z", "2026-10-03T15:30:00Z", 23.5),
])
func jevTodayFollowsHalfHourDSTCalendarHours(
    _ timestamp: String, _ transitionTimestamp: String, _ dayHours: Double
) throws {
    let now = jevDate(timestamp)
    let transition = jevDate(transitionTimestamp)
    let calendar = jevCalendar("Australia/Lord_Howe")
    let midnight = calendar.startOfDay(for: now)
    let nextMidnight = try #require(calendar.date(byAdding: .day, value: 1, to: midnight))
    let calls = [jevCall(transition.addingTimeInterval(15 * 60), input: 50),
                 jevCall(nextMidnight, input: 100)]
    let report = JevUsage.report(calls, range: .today, now: nextMidnight.addingTimeInterval(-1),
                                 calendar: calendar)
    let points = report.series.points
    #expect(nextMidnight.timeIntervalSince(midnight) == dayHours * 3600)
    #expect(points.first?.start == midnight && points.last?.end == nextMidnight)
    #expect(points.allSatisfy { calendar.component(.minute, from: $0.start) == 0 || $0.start == transition })
    #expect(zip(points, points.dropFirst()).allSatisfy { $0.end == $1.start })
    let bucket = try #require(points.first { $0.start <= transition.addingTimeInterval(15 * 60)
        && transition.addingTimeInterval(15 * 60) < $0.end })
    #expect(bucket.totalTokens == 53)
    #expect(report.totals.requests == 1) // next midnight belongs to tomorrow
}

@Test func jevTimestampPrecisionMatchesAPIDateParser() throws {
    let timestamps = ["2026-10-03T05:12:18Z", "2026-10-03T05:12:18.123Z",
        "2026-10-03T05:12:18.123456789Z", "2026-10-03T05:12:18.123456789+05:30",
        "2026-10-03T05:12:18.1Z"]
    let lines = timestamps.map { "{\"ts\":\"\($0)\"}" }.joined(separator: "\n")
    let parsed = JevLog.parse(Data(lines.utf8))
    #expect(parsed.skippedLines == 0)
    #expect(parsed.calls.map(\.timestamp) == timestamps.compactMap(APIDateParser.parse).sorted())
}

@Test func jevOutOfOrderLinesBinByTimestamp() throws {
    let lines = ["2026-10-03T14:00:00Z", "2026-10-03T01:00:00Z", "2026-10-03T05:00:00Z"]
        .enumerated().map { index, timestamp in
            "{\"ts\":\"\(timestamp)\",\"input_tokens\":\(index + 1)}"
        }
    let parsed = JevLog.parse(Data(lines.joined(separator: "\n").utf8))
    #expect(parsed.calls.map(\.inputTokens) == [2, 3, 1])
    let report = JevUsage.report(parsed.calls, range: .today, now: jevNow, calendar: jevCalendar())
    #expect(report.series.points[1].totalTokens == 2)
    #expect(report.series.points[5].totalTokens == 3)
    #expect(report.series.points[14].totalTokens == 1)
}

@Test func jevLateTimeoutCountsSpendWithoutFailure() throws {
    let lines = [
        "{\"ts\":\"2026-10-03T05:00:00Z\",\"input_tokens\":1000000,\"output_tokens\":20,\"latency_ms\":60000,\"ok\":false,\"error\":\"timeout\"}",
        "{\"ts\":\"2026-10-03T06:00:00Z\",\"ok\":false,\"error\":\"network\"}"
    ]
    let calls = JevLog.parse(Data(lines.joined(separator: "\n").utf8)).calls
    #expect(calls[0].isLate && !calls[0].isFailure)
    #expect(calls[0].latencyMs == 60000)
    #expect(calls[1].isFailure && !calls[1].isLate)
    let report = JevUsage.report(calls, range: .today, now: jevNow, calendar: jevCalendar())
    #expect(report.totals.requests == 2)
    #expect(report.totals.failed == 1 && report.totals.late == 1)
    #expect(report.totals.totalTokens == 1_000_020)
    #expect(report.totals.estimatedSpendUSD == 0.042)
    #expect(report.totals.failuresByError == ["network": 1])
    #expect(JevTotals().late == 0)
}

@Test func jevScanFollowsSymlinkedFolderAndFile() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logs = directory.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
    let target = directory.appendingPathComponent("target")
    try Data(jevLine.utf8).write(to: target)
    let file = logs.appendingPathComponent("usage-link.jsonl")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    let folder = directory.appendingPathComponent("linked-logs")
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: logs)
    #expect(JevLog.read(file) == .loaded(JevLog.parse(Data(jevLine.utf8))))
    let scan = JevLog.scan(directory: folder, previous: [:], modifiedSince: .distantPast)
    #expect(scan.read == .loaded(JevLog.parse(Data(jevLine.utf8))))
    #expect(scan.files.keys.sorted() == ["usage-link.jsonl"])
    #expect(scan.warning == nil)
}

@Test func jevVanishedCachedFileIsNotFailure() throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    try Data(jevLine.utf8).write(to: target)
    let file = directory.appendingPathComponent("usage-link.jsonl")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    let initial = JevLog.scan(directory: directory, previous: [:], modifiedSince: .distantPast)
    #expect(initial.files.count == 1)
    try FileManager.default.removeItem(at: target)
    // The name still appears in the directory listing, but stat returns ENOENT.
    let scan = JevLog.scan(directory: directory, previous: initial.files, modifiedSince: .distantPast)
    #expect(scan.files.isEmpty)
    #expect(scan.read == .missing)
    #expect(scan.warning == nil)
}

@MainActor @Test func jevOnlyOldFilesRemainLoadedWithLastCall() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let calendar = jevCalendar()
    let start = try #require(UsageRange.allCases.map { $0.start(now: jevNow, calendar: calendar) }.min())
    let cutoff = try #require(calendar.date(byAdding: .day, value: -1, to: start))
    let newest = cutoff.addingTimeInterval(-1)
    for (index, date) in [newest.addingTimeInterval(-86400), newest].enumerated() {
        let file = directory.appendingPathComponent("usage-\(index).jsonl")
        try Data(jevLine.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }
    let scan = JevLog.scan(directory: directory, previous: [:], modifiedSince: cutoff)
    #expect(scan.read == .loaded(JevLogParse(calls: [], skippedLines: 0)))
    #expect(scan.latestOutsideWindow == newest)
    #expect(scan.warning == nil)
    let monitor = JevUsageMonitor(directory: directory, calendar: calendar, now: { jevNow })
    await monitor.reload()
    #expect(monitor.log == .loaded)
    for range in UsageRange.allCases {
        #expect(monitor.state(for: range) == .empty(lastCall: newest))
    }
}

@MainActor @Test func jevMonitorScansEarliestSupportedRange() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let calendar = jevCalendar()
    let range = try #require(UsageRange.allCases.min {
        $0.start(now: jevNow, calendar: calendar) < $1.start(now: jevNow, calendar: calendar)
    })
    let start = range.start(now: jevNow, calendar: calendar)
    let file = directory.appendingPathComponent("usage-earliest.jsonl")
    let timestamp = ISO8601DateFormatter().string(from: start)
    try Data("{\"ts\":\"\(timestamp)\",\"input_tokens\":10}".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)
    let monitor = JevUsageMonitor(directory: directory, calendar: calendar, now: { jevNow })
    await monitor.reload()
    #expect(monitor.reports[range]?.totals.requests == 1)
    #expect(monitor.lastCall == start)
}

@MainActor @Test func jevMonitorRecomputesAfterWholeHourTimeZoneChange() async throws {
    let directory = try jevTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(jevLine.utf8).write(to: directory.appendingPathComponent("usage-test.jsonl"))
    let calendar = Mutex(jevCalendar())
    let monitor = JevUsageMonitor(directory: directory, now: { jevNow },
                                  calendarProvider: { calendar.withLock { $0 } })
    await monitor.reload()
    #expect(monitor.reports[.today]?.series.points[5].totalTokens == 127)
    calendar.withLock { $0 = jevCalendar("Europe/Athens") }
    await monitor.reload()
    #expect(monitor.reports[.today]?.start == jevDate("2026-10-02T21:00:00Z"))
    #expect(monitor.reports[.today]?.series.points[8].totalTokens == 127)
    #expect(monitor.reports[.today]?.series.points[5].totalTokens == 0)
}
