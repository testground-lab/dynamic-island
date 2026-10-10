import Foundation
import Darwin
import Testing
import Synchronization
@testable import IslandCore

private func projectDate(_ text: String) -> Date { APIDateParser.parse(text)! }
private let projectNow = projectDate("2026-10-09T15:00:00Z")
private func projectCalendar(_ zone: String = "UTC") -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: zone)!
    return value
}
private func projectTemp() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory.path
    let physical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
    let root = URL(fileURLWithPath: physical).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
@discardableResult
private func projectWrite(_ root: URL, _ name: String, _ lines: String) throws -> URL {
    let file = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.utf8).write(to: file)
    return file
}
private func claudeProject(_ id: String = "message", session: String = "session", cwd: String? = "/fake/project",
                           date: String = "2026-10-09T12:00:00Z", input: String = "10", output: String = "2",
                           cacheRead: String = "3", cacheWrite: String = "4") -> String {
    let cwdField = cwd.map { ",\"cwd\":\"\($0)\"" } ?? ""
    return "{\"type\":\"assistant\",\"timestamp\":\"\(date)\",\"sessionId\":\"\(session)\"\(cwdField),\"message\":{\"id\":\"\(id)\",\"content\":[{\"text\":\"private transcript must not survive\"}],\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheWrite)}}}"
}
private func codexProject(_ id: String = "response", session: String = "session", date: String = "2026-10-09T12:00:00Z",
                          input: String = "20", output: String = "2", cached: String = "7", written: String = "3",
                          reasoning: String = "1", total: String = "22") -> String {
    "{\"type\":\"token_usage_record\",\"timestamp\":\"\(date)\",\"ordinal\":14,\"payload\":{\"session_id\":\"\(session)\",\"thread_id\":\"thread\",\"turn_id\":\"turn\",\"root_turn_id\":\"root-turn\",\"response_id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"cache_write_input_tokens\":\(written),\"output_tokens\":\(output),\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(total)},\"turn_token_usage\":{\"input_tokens\":99999},\"thread_token_usage\":{\"input_tokens\":999999}}}"
}
private func codexContext(_ cwd: String, session: String = "session") -> String {
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"\(cwd)\"}}"
}
private func projectReport(_ snapshot: ProjectUsageSnapshot, range: UsageRange = .today,
                           source: ProjectUsageSource? = nil, now: Date = projectNow,
                           calendar: Calendar = projectCalendar()) -> ProjectUsageReport {
    ProjectUsageReducer.publish(snapshot, now: now, calendar: calendar)
        .reports[.init(range: range, source: source)]!
}

@Test func projectExactSchemasCacheArithmeticAndSourceIndependentPaths() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "claude/a.jsonl", claudeProject() + "\n")
    try projectWrite(root, "codex/rollout-a.jsonl", codexProject() + "\n" + codexContext("/fake/project") + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root.appendingPathComponent("claude"),
                                                           .codex: root.appendingPathComponent("codex")], now: projectNow)
    let report = projectReport(scan)
    #expect(scan.warnings.isEmpty)
    #expect(report.totals == .init(responses: 2, inputTokens: 37, outputTokens: 4,
                                  cacheReadTokens: 10, cacheWriteTokens: 7, totalTokens: 41))
    #expect(report.projects.count == 1)
    #expect(report.projects.first?.path == "/fake/project")
    #expect(projectReport(scan, source: .codex).totals.totalTokens == 22)
    #expect(projectReport(scan, source: .claudeCode).totals.totalTokens == 19)
    #expect(!String(describing: scan).contains("private transcript"))
}

@Test func projectDedupAcrossFilesBeforeRangeAndLatestValidSnapshot() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject(date: "2026-10-08T10:00:00Z") + "\n")
    try projectWrite(root, "b.jsonl", claudeProject(date: "2026-10-09T10:00:00Z", input: "30") + "\n" +
                     claudeProject(date: "2026-10-09T11:00:00Z", input: "-1") + "\n")
    let scanner = ProjectUsageScanner()
    let scan = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(projectReport(scan).totals.responses == 1)
    #expect(projectReport(scan).totals.inputTokens == 37)
    #expect(projectReport(scan, range: .week).totals.responses == 1)
    // A future latest snapshot replaces the old one before range reduction; no stale fallback.
    try projectWrite(root, "c.jsonl", claudeProject(date: "2026-10-10T00:00:00Z") + "\n")
    let future = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    let publication = ProjectUsageReducer.publish(future, now: projectNow, calendar: projectCalendar())
    #expect(projectReport(future).totals.responses == 0)
    #expect(publication.warning?.contains("Future-dated") == true)
    #expect(publication.lastResponse == nil)
}

@Test func projectEqualTimestampConflictsStablePathAndLineTie() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject(input: "20") + "\n")
    try projectWrite(root, "z.jsonl", claudeProject(input: "30") + "\n" + claudeProject(input: "40") + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    let publication = ProjectUsageReducer.publish(scan, now: projectNow, calendar: projectCalendar())
    #expect(projectReport(scan).totals.inputTokens == 47)
    #expect(publication.warning?.contains("Conflicting response snapshots") == true)
}

@Test func projectCodexDeltaDedupNeverSumsCumulativeOrLegacy() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":400},\"total_token_usage\":{\"input_tokens\":800}}}}"
    try projectWrite(root, "rollout-a.jsonl", codexProject() + "\n" + codexProject("second") + "\n" + legacy + "\n")
    try projectWrite(root, "rollout-b.jsonl", codexProject() + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(projectReport(scan).totals.totalTokens == 44)
    #expect(projectReport(scan).totals.responses == 2)
    #expect(!scan.warnings.contains(where: { $0.contains("Legacy") }))
    try FileManager.default.removeItem(at: root.appendingPathComponent("rollout-b.jsonl"))
    try projectWrite(root, "rollout-a.jsonl", legacy + "\n")
    let onlyLegacy = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(onlyLegacy.state == .loaded)
    #expect(projectReport(onlyLegacy).totals.responses == 0)
    #expect(!onlyLegacy.warnings.isEmpty)
}

@Test func projectMissingAmbiguousLateCrossFileMetadataAndExplicitCWD() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject("inferred", cwd: nil) + "\n" + claudeProject("explicit", cwd: "/explicit/project") + "\n")
    try projectWrite(root, "b.jsonl", "{\"type\":\"user\",\"sessionId\":\"session\",\"cwd\":\"/other/project\",\"timestamp\":\"2026-10-10T00:00:00Z\"}\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    let report = projectReport(scan)
    #expect(report.projects.contains(where: { $0.path == nil && $0.totals.responses == 1 }))
    #expect(report.projects.contains(where: { $0.path == "/explicit/project" }))
    // Metadata after the response and in another copied file applies to the entire Codex session.
    try projectWrite(root, "rollout-a.jsonl", codexProject() + "\n")
    try projectWrite(root, "rollout-b.jsonl", codexContext("/late/project") + "\n")
    let codex = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(projectReport(codex).projects.first?.path == "/late/project")
    try projectWrite(root, "rollout-c.jsonl", codexContext("/different/project") + "\n")
    let conflict = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(projectReport(conflict).projects.first?.path == nil)
}

@Test func projectStandardPathsDuplicateBasenamesAndWorktreesRemainDistinct() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ["/one/app", "/two/app", "/one/app/../app", "/one/app/.worktrees/feature", "relative/path"]
    try projectWrite(root, "a.jsonl", paths.enumerated().map {
        claudeProject("response-\($0.offset)", session: "session-\($0.offset)", cwd: $0.element)
    }.joined(separator: "\n") + "\n")
    let report = projectReport(try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow))
    #expect(report.projects.count == 4)
    #expect(report.projects.first(where: { $0.path == "/one/app" })?.totals.responses == 2)
    #expect(report.projects.first(where: { $0.path == "/one/app" })?.name == "app — /one")
    #expect(report.projects.first(where: { $0.path == "/two/app" })?.name == "app — /two")
    #expect(report.projects.contains(where: { $0.path == "/one/app/.worktrees/feature" }))
    #expect(report.projects.contains(where: { $0.name == "Unattributed" && $0.path == nil }))
}

@Test(arguments: ["-1", "2.5", "true", "\"2\"", "9223372036854775808", "null"])
func projectStrictRequiredNumericFields(_ input: String) async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject(input: input) + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.records.isEmpty)
    #expect(!scan.warnings.isEmpty)
}

@Test func projectOptionalCacheAbsentMissingIDsOverflowAndUnknownEvents() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let good = "{\"type\":\"assistant\",\"timestamp\":\"2026-10-09T12:00:00Z\",\"sessionId\":\"s\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}}"
    let missing = good.replacingOccurrences(of: "\"id\":\"m\",", with: "")
    try projectWrite(root, "a.jsonl", good + "\n" + missing + "\n" + claudeProject(input: String(Int.max)) + "\n" +
                     "{\"type\":\"progress\",\"content\":{\"private\":true}}\n{\"type\":\"new_usage_format\"}\n{broken\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.records.count == 1)
    #expect(projectReport(scan).totals == .init(responses: 1, inputTokens: 1, outputTokens: 2, totalTokens: 3))
    #expect(scan.warnings.contains(where: { $0.contains("Unsupported") }))
    #expect(scan.warnings.contains(where: { $0.contains("overflow") }))
    #expect(scan.warnings.contains(where: { $0.contains("Malformed") }))
    #expect(!scan.warnings.contains(where: { $0.contains("progress") }))
}

@Test func projectAggregateOverflowSkipsInsteadOfTrapping() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = claudeProject("huge", input: String(Int.max - 10), output: "0", cacheRead: "0", cacheWrite: "0")
    try projectWrite(root, "a.jsonl", line + "\n" + claudeProject("ordinary") + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    let result = ProjectUsageReducer.publish(scan, now: projectNow, calendar: projectCalendar())
    #expect(projectReport(scan).totals.responses == 1)
    #expect(result.warning?.contains("aggregation overflow") == true)
}

@Test func projectCodexRejectsInvalidSubsetsAndWarnsInconsistentTotal() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "rollout-a.jsonl", codexProject("bad-cache", cached: "18") + "\n" +
                     codexProject("bad-output", reasoning: "3") + "\n" + codexProject("ok", total: "999") + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(scan.records.count == 1)
    #expect(projectReport(scan).totals.totalTokens == 22)
    #expect(scan.warnings.contains(where: { $0.contains("inconsistent") }))
}

@Test(arguments: ["UTC", "America/New_York", "Australia/Lord_Howe"])
func projectRangesUseCalendarStartsAndRejectFuture(_ zone: String) async throws {
    let calendar = projectCalendar(zone)
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = calendar.startOfDay(for: projectNow)
    let formatter = ISO8601DateFormatter()
    try projectWrite(root, "a.jsonl", claudeProject("start", date: formatter.string(from: start)) + "\n" +
                     claudeProject("before", date: formatter.string(from: start.addingTimeInterval(-1))) + "\n")
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(projectReport(scan, calendar: calendar).totals.responses == 1)
    #expect(projectReport(scan, range: .week, calendar: calendar).totals.responses == 2)
}

@Test func projectScannerCacheRewriteAppendTruncateDeleteAndPartialEOF() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let scanner = ProjectUsageScanner()
    let first = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    let second = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(first.records == second.records)
    #expect(await scanner.streamedFiles == 1)
    // Same size whole rewrite must be detected by inode/mtime/ctime, not size alone.
    try Data((claudeProject(input: "11") + "\n").utf8).write(to: file)
    #expect(projectReport(try await scanner.scan(roots: [.claudeCode: root], now: projectNow)).totals.inputTokens == 18)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(claudeProject("second").utf8))
    try handle.close()
    let partial = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(partial.records.count == 1)
    #expect(partial.warnings.contains(where: { $0.contains("unfinished") }))
    let append = try FileHandle(forWritingTo: file)
    try append.seekToEnd(); try append.write(contentsOf: Data("\n".utf8)); try append.close()
    #expect(try await scanner.scan(roots: [.claudeCode: root], now: projectNow).records.count == 2)
    try Data().write(to: file)
    #expect(try await scanner.scan(roots: [.claudeCode: root], now: projectNow).records.isEmpty)
    try FileManager.default.removeItem(at: file)
    let deleted = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(deleted.records.isEmpty)
    #expect(deleted.state == .loaded)
}

@Test func projectScannerCRLFUTF8ChunkBoundaryAndOversizeRecovery() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    var data = Data((claudeProject("first", cwd: "/fake/日本語") + "\r\n").utf8)
    data.append(contentsOf: [255, 254, 10])
    data.append(Data((String(repeating: "x", count: 2048) + "\n" + claudeProject("second") + "\n").utf8))
    let file = try projectWrite(root, "a.jsonl", "")
    try data.write(to: file)
    var limits = ProjectUsageLimits(); limits.lineBytes = 1024; limits.chunkBytes = 7
    let scan = try await ProjectUsageScanner(limits: limits).scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.records.count == 2)
    #expect(projectReport(scan).projects.contains(where: { $0.path == "/fake/日本語" }))
    #expect(!scan.warnings.contains(where: { $0.contains("oversized") }))
    #expect(scan.warnings.contains(where: { $0.contains("Malformed") }))
}

@Test func projectScannerDoesNotCommitRotatedOrModifiedDescriptor() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let mutate = Mutex(true)
    let scanner = ProjectUsageScanner(afterRead: { url in
        let change = mutate.withLock { value in let previous = value; value = false; return previous }
        if change { try? Data((claudeProject("replacement") + "\n").utf8).write(to: url, options: .atomic) }
    })
    let unstable = try await scanner.scan(roots: [.claudeCode: root], now: projectNow, calendar: projectCalendar())
    #expect(unstable.publication?.reports[.init(range: .today, source: nil)]?.totals.responses ?? 0 == 0)
    #expect(!unstable.progress.ready)
    let stable = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(stable.records.first?.response == "replacement")
    #expect(await scanner.streamedFiles == 2)
}

@Test func projectScannerSkipsSymlinkDirectoriesLeavesAndNonregularFiles() async throws {
    let root = try projectTemp(), outside = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let target = try projectWrite(outside, "a.jsonl", claudeProject() + "\n")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jsonl"), withDestinationURL: target)
    #expect(mkfifo(root.appendingPathComponent("pipe.jsonl").path, 0o600) == 0)
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.records.isEmpty)
    #expect(scan.warnings.isEmpty)
    let symlinkRoot = try await ProjectUsageScanner().scan(roots: [.claudeCode: root.appendingPathComponent("linked")], now: projectNow)
    #expect(symlinkRoot.state != .loaded)
}

@Test func projectMissingUnreadableAndPartialSourceSuccess() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let absent = try await ProjectUsageScanner().scan(roots: [.claudeCode: root.appendingPathComponent("missing")], now: projectNow)
    #expect(absent.state == .missing)
    let notDirectory = try projectWrite(root, "not-folder", "x")
    let unreadable = try await ProjectUsageScanner().scan(roots: [.claudeCode: notDirectory], now: projectNow)
    #expect(unreadable.state == .unreadable("Local usage folders couldn't be read"))
    try projectWrite(root, "codex/rollout-a.jsonl", codexProject() + "\n")
    let partial = try await ProjectUsageScanner().scan(roots: [.claudeCode: notDirectory, .codex: root.appendingPathComponent("codex")], now: projectNow)
    #expect(partial.state == .loaded)
    #expect(partial.records.count == 1)
    #expect(!partial.warnings.isEmpty)
}

@Test func projectScannerFairByteBudgetsAndCachedRecordsStayBudgeted() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "claude/huge.jsonl", String(repeating: "x", count: 8192) + "\n")
    try projectWrite(root, "claude/small.jsonl", claudeProject() + "\n")
    try projectWrite(root, "codex/rollout-a.jsonl", codexProject() + "\n")
    var limits = ProjectUsageLimits(); limits.bytes = 4096; limits.files = 1
    let scanner = ProjectUsageScanner(limits: limits)
    let roots: [ProjectUsageSource: URL] = [.claudeCode: root.appendingPathComponent("claude"), .codex: root.appendingPathComponent("codex")]
    let first = try await scanner.scan(roots: roots, now: projectNow)
    let second = try await scanner.scan(roots: roots, now: projectNow)
    #expect(first.records.count == 2)
    #expect(second.records.count == 2)
    #expect(await scanner.streamedFiles == 3) // Giant file is progressed, not permanently excluded.
    #expect(first.warnings.contains(where: { $0.contains("Malformed") }))
}

@Test func projectScannerResidentRecordDiscoveryAndStringBounds() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "claude/a.jsonl", claudeProject() + "\n")
    try projectWrite(root, "codex/rollout-a.jsonl", codexProject() + "\n")
    var tiny = ProjectUsageLimits(); tiny.residentBytes = 100
    let roots: [ProjectUsageSource: URL] = [.claudeCode: root.appendingPathComponent("claude"), .codex: root.appendingPathComponent("codex")]
    let limited = try await ProjectUsageScanner(limits: tiny).scan(roots: roots, now: projectNow)
    #expect(limited.records.count == 2)
    #expect(limited.warnings.isEmpty)
    tiny = ProjectUsageLimits(); tiny.records = 1
    let records = try await ProjectUsageScanner(limits: tiny).scan(roots: roots, now: projectNow)
    #expect(Set(records.records.map(\.source)) == Set(ProjectUsageSource.allCases))
    tiny = ProjectUsageLimits(); tiny.discoveryEntries = 1
    let discovered = try await ProjectUsageScanner(limits: tiny).scan(roots: roots, now: projectNow)
    #expect(discovered.records.count == 2)
    #expect(discovered.warnings.isEmpty)
    try projectWrite(root, "claude/a.jsonl", claudeProject(String(repeating: "x", count: 4097)) + "\n")
    let stringBound = try await ProjectUsageScanner().scan(roots: [.claudeCode: root.appendingPathComponent("claude")], now: projectNow)
    #expect(stringBound.records.isEmpty)
    #expect(!stringBound.warnings.isEmpty)
}

@Test func projectOldMtimeDoesNotExcludeRetainedUsageAndUnknownEventsEmptyLoaded() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    try FileManager.default.setAttributes([.modificationDate: projectNow.addingTimeInterval(-184 * 86400)], ofItemAtPath: file.path)
    let scan = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.state == .loaded)
    #expect(scan.records.count == 1)
    try projectWrite(root, "b.jsonl", "{\"type\":\"progress\",\"timestamp\":\"not used\"}\n")
    try FileManager.default.removeItem(at: file)
    let unknown = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(unknown.records.isEmpty)
    #expect(unknown.warnings.isEmpty)
}

@Test @MainActor func projectMonitorClockRolloverMissingEmptyAndDemo() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let clock = Mutex(projectNow)
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], calendar: projectCalendar(), now: { clock.withLock { $0 } })
    #expect(monitor.log == .loading)
    #expect(monitor.report(for: .today) == nil)
    await monitor.reload()
    #expect(monitor.report(for: .today)?.totals.responses == 1)
    clock.withLock { $0 = projectDate("2026-10-10T00:00:00Z") }
    await monitor.reload()
    #expect(monitor.report(for: .today)?.totals.responses == 0)
    #expect(monitor.report(for: .week)?.totals.responses == 1)
    #expect(monitor.lastResponse == projectDate("2026-10-09T12:00:00Z"))
    let missing = ProjectUsageMonitor(roots: [:])
    await missing.reload()
    #expect(missing.log == .missing)
    #expect(missing.report(for: .today) == nil)
    let demo = ProjectUsageMonitor.demo(now: projectNow, calendar: projectCalendar())
    #expect(demo.isDemo)
    #expect(demo.report(for: .today)?.totals.responses == 3)
    demo.start(); demo.refresh(); await demo.reload(); demo.stop()
    #expect(demo.log == .loaded)
    #expect(demo.report(for: .today)?.totals.responses == 3)
    monitor.stop()
}

@Test func projectPerPassFileAndByteBudgetsDeferInsteadOfDroppingHistory() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = claudeProject() + "\n"
    for index in 0..<5 { try projectWrite(root, "\(index).jsonl", text) }
    var limits = ProjectUsageLimits(); limits.residentBytes = 100; limits.files = 2
    let fileScanner = ProjectUsageScanner(limits: limits)
    let first = try await fileScanner.scan(roots: [.claudeCode: root], now: projectNow, calendar: projectCalendar())
    #expect(first.needsMoreWork)
    #expect(await fileScanner.streamedFiles <= limits.files)
    let files = try await fileScanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(files.records.count == 5)
    #expect(await fileScanner.streamedFiles == 5)
    #expect(files.warnings.isEmpty)
    limits.files = 256; limits.bytes = text.utf8.count * 2
    let byteScanner = ProjectUsageScanner(limits: limits)
    let initial = try await byteScanner.scan(roots: [.claudeCode: root], now: projectNow, calendar: projectCalendar())
    #expect(initial.needsMoreWork)
    #expect(await byteScanner.streamedBytes <= limits.bytes)
    let bytes = try await byteScanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(bytes.records.count == 5)
    #expect(await byteScanner.streamedBytes == text.utf8.count * 5)
}

@Test func projectGrowthCannotReadBeyondChargedDescriptorSize() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = claudeProject() + "\n"
    try projectWrite(root, "a.jsonl", text)
    var limits = ProjectUsageLimits(); limits.bytes = text.utf8.count
    let scanner = ProjectUsageScanner(limits: limits, beforeRead: { url in
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(repeating: 32, count: 10_000))
            try? handle.close()
        }
    })
    let scan = try await scanner.scan(roots: [.claudeCode: root], now: projectNow)
    #expect(scan.records.count == 1) // Complete records through the finite captured size remain valid.
    #expect(!scan.warnings.contains(where: { $0.contains("changed during scan") }))
    #expect(await scanner.streamedBytes == text.utf8.count)
}

@Test func projectMissingSourceIsExplicitAlongsideLoadedOtherSource() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let snapshot = try await ProjectUsageScanner().scan(
        roots: [.claudeCode: root, .codex: root.appendingPathComponent("absent")], now: projectNow)
    let publication = ProjectUsageReducer.publish(snapshot, now: projectNow, calendar: projectCalendar())
    #expect(snapshot.state == .loaded)
    #expect(projectReport(snapshot).totals.responses == 1)
    #expect(projectReport(snapshot, source: .codex).totals.responses == 0)
    #expect(publication.warning?.contains("Codex source folder missing") == true)
}

@Test func projectAmbiguousCodexFileCannotBeReattributedByCleanCopy() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "rollout-mixed.jsonl", codexProject("one", session: "s-one") + "\n" +
                     codexProject("two", session: "s-two") + "\n" + codexContext("/ambiguous", session: "s-one") + "\n")
    try projectWrite(root, "rollout-clean.jsonl", codexContext("/apparently-clean", session: "s-one") + "\n")
    let snapshot = try await ProjectUsageScanner().scan(roots: [.codex: root], now: projectNow)
    #expect(snapshot.records.count == 2)
    #expect(projectReport(snapshot).projects.count == 1)
    #expect(projectReport(snapshot).projects.first?.path == nil)
    #expect(snapshot.warnings.contains(where: { $0.contains("context ambiguous") }))
}

@Test func projectEqualCountsDifferentCWDWarnsWithoutMergingProjects() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject(cwd: "/one/project") + "\n")
    try projectWrite(root, "z.jsonl", claudeProject(cwd: "/two/project") + "\n")
    let snapshot = try await ProjectUsageScanner().scan(roots: [.claudeCode: root], now: projectNow)
    #expect(projectReport(snapshot).projects.first?.path == "/two/project")
    let publication = ProjectUsageReducer.publish(snapshot, now: projectNow, calendar: projectCalendar())
    #expect(publication.warning?.contains("Conflicting response snapshots") == true)
}

@Test @MainActor func projectQueuedRefreshThenImmediateStopDoesNotScanOrPublish() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let scanner = ProjectUsageScanner()
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], scanner: scanner,
                                      calendar: projectCalendar(), now: { projectNow })
    monitor.refresh(); monitor.stop()
    for _ in 0..<10 { await Task.yield() }
    #expect(await scanner.streamedFiles == 0)
    #expect(monitor.log == .loading)
    #expect(monitor.report(for: .today) == nil)
    await monitor.reload()
    #expect(await scanner.streamedFiles == 1)
    #expect(monitor.log == .loaded)
    monitor.stop()
}

@Test @MainActor func projectMonitorCoalescesOverlapsAndStopRejectsStalePublication() async throws {
    let root = try projectTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    try projectWrite(root, "a.jsonl", claudeProject() + "\n")
    let entered = Mutex(false), release = Mutex(false)
    let scanner = ProjectUsageScanner(afterRead: { _ in
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
    })
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], scanner: scanner,
                                      calendar: projectCalendar(), now: { projectNow })
    let one = Task { await monitor.reload() }
    for _ in 0..<1000 {
        if entered.withLock({ $0 }) { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(entered.withLock { $0 })
    let two = Task { await monitor.reload() }
    await Task.yield()
    monitor.stop()
    release.withLock { $0 = true }
    await one.value; await two.value
    #expect(monitor.log == .loading)
    #expect(monitor.report(for: .today) == nil)
    await monitor.reload()
    #expect(monitor.log == .loaded)
    #expect(monitor.report(for: .today)?.totals.responses == 1)
    // Canceled scan never committed its cache, so restarting restreams the file.
    #expect(await scanner.streamedFiles == 2)
    monitor.stop()
}
