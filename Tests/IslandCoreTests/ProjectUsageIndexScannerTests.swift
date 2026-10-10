import Foundation
import Darwin
import Synchronization
import Testing
@testable import IslandCore

private let indexScanNow = APIDateParser.parse("2026-10-09T12:00:00Z")!
private func indexScanCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
private func indexScanTemp() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory.path
    let physical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
    let url = URL(fileURLWithPath: physical).appendingPathComponent("project-scanner-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func indexScanClaude(_ id: String, cwd: String = "/fixture/project", input: Int = 10) -> String {
    "{\"type\":\"assistant\",\"timestamp\":\"2026-10-09T11:00:00Z\",\"sessionId\":\"session\",\"cwd\":\"\(cwd)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":2,\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":4}}}\n"
}
@discardableResult
private func indexScanWrite(_ root: URL, name: String, text: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}
private func indexScanDrain(_ scanner: ProjectUsageScanner, roots: [ProjectUsageSource: URL],
                            maxPasses: Int = 20_000) async throws -> ProjectUsagePublication {
    var last: ProjectUsagePublication?
    for _ in 0..<maxPasses {
        let result = try await scanner.scan(roots: roots, now: indexScanNow, calendar: indexScanCalendar())
        if let publication = result.publication { last = publication }
        if !result.needsMoreWork {
            let cached = await scanner.currentPublication()
            return try #require(cached ?? last)
        }
    }
    Issue.record("A finite fixture corpus did not finish its progressive passes")
    throw CancellationError()
}
private func indexScanToday(_ publication: ProjectUsagePublication) throws -> ProjectUsageReport {
    try #require(publication.reports[.init(range: .today, source: nil)])
}

@Test func projectIndexScannerGiantUsageAndNonusageLinesHaveNoExclusionWarning() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let body = String(repeating: "x", count: 600_000)
    let assistant = indexScanClaude("giant").replacingOccurrences(of: "\"id\":\"giant\",", with: "\"content\":\"\(body)\",\"id\":\"giant\",")
    try indexScanWrite(root, name: "large.jsonl", text: "{\"type\":\"user\",\"content\":\"\(body)\"}\n" + assistant)
    var limits = ProjectUsageLimits(); limits.bytes = 64 * 1024; limits.files = 1
    let scanner = ProjectUsageScanner(limits: limits)
    let first = try await scanner.scan(roots: [.claudeCode: root], now: indexScanNow, calendar: indexScanCalendar())
    #expect(first.needsMoreWork)
    let complete = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(complete).totals.responses == 1)
    #expect(try indexScanToday(complete).totals.inputTokens == 17)
    #expect(complete.warning == nil)
    #expect(complete.progress.ready)
}

@Test func projectIndexScannerCorpusBeyondOld64MiBFinishesAndRestartIsWarm() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("logs")
    let file = try indexScanWrite(source, name: "huge.jsonl", text: "{\"type\":\"user\",\"content\":\"")
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    let chunk = Data(repeating: 120, count: 1024 * 1024)
    for _ in 0..<65 { try handle.write(contentsOf: chunk) }
    try handle.write(contentsOf: Data(("\"}\n" + indexScanClaude("after-backlog")).utf8)); try handle.close()
    let url = root.appendingPathComponent("cache/index.sqlite")
    let scanner = ProjectUsageScanner(indexURL: url)
    let cold = try await indexScanDrain(scanner, roots: [.claudeCode: source])
    #expect(try indexScanToday(cold).totals.responses == 1)
    #expect(await scanner.streamedBytes > 64 * 1024 * 1024)
    let restarted = ProjectUsageScanner(indexURL: url)
    let warm = try await indexScanDrain(restarted, roots: [.claudeCode: source])
    #expect(try indexScanToday(warm).totals == indexScanToday(cold).totals)
    #expect(await restarted.streamedBytes == 0)
}

@Test func projectIndexScannerDiscoveryResumesInsteadOfAdmittingOnlyPrefix() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    for id in 0..<40 { try indexScanWrite(root, name: "folder/\(id).jsonl", text: indexScanClaude("response-\(id)")) }
    var limits = ProjectUsageLimits(); limits.discoveryEntries = 3; limits.files = 2; limits.bytes = 2048
    let scanner = ProjectUsageScanner(limits: limits)
    let publication = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(publication).totals.responses == 40)
    #expect(publication.warning == nil)
}

@Test func projectIndexScannerRestartResumesCompleteLineCheckpointWithoutDuplicateCounts() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("logs")
    try indexScanWrite(source, name: "a.jsonl", text: (0..<30).map { indexScanClaude("r-\($0)") }.joined())
    let url = root.appendingPathComponent("cache/index.sqlite")
    var limits = ProjectUsageLimits(); limits.bytes = 1024; limits.files = 1
    let first = ProjectUsageScanner(limits: limits, indexURL: url)
    let partial = try await first.scan(roots: [.claudeCode: source], now: indexScanNow, calendar: indexScanCalendar())
    #expect(partial.needsMoreWork)
    await first.cancel()
    let second = ProjectUsageScanner(limits: limits, indexURL: url)
    let complete = try await indexScanDrain(second, roots: [.claudeCode: source])
    #expect(try indexScanToday(complete).totals.responses == 30)
    #expect(await second.streamedBytes < 30 * indexScanClaude("r-0").utf8.count)
}

@Test func projectIndexScannerAppendedTailAndPrefixRewriteReplaceOldContribution() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude("old", input: 10))
    let scanner = ProjectUsageScanner()
    _ = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    // Same inode, larger file: hashing must not mistake rewritten prefix for append.
    try Data((indexScanClaude("old", input: 90) + indexScanClaude("new")).utf8).write(to: file)
    let replaced = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(replaced).totals.responses == 2)
    #expect(try indexScanToday(replaced).totals.inputTokens == 114)
    try Data().write(to: file)
    #expect(try indexScanToday(await indexScanDrain(scanner, roots: [.claudeCode: root])).totals.responses == 0)
}

@Test func projectIndexScannerFiniteHighWatermarkFinishesDespiteAppender() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude("captured"))
    let wrote = Mutex(false)
    let scanner = ProjectUsageScanner(afterRead: { url in
        let append = wrote.withLock { value in let prior = value; value = true; return !prior }
        if append, let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(indexScanClaude("later").utf8)); try? handle.close()
        }
    })
    let first = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(first).totals.responses == 1)
    let next = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(next).totals.responses == 2)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test @MainActor func projectIndexMonitorKeysetPagesRetainCompleteTotals() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    try indexScanWrite(root, name: "a.jsonl", text: (0..<45).map {
        indexScanClaude("r-\($0)", cwd: "/fixture/project-\($0)", input: 100 + $0)
    }.joined())
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], now: { indexScanNow })
    await monitor.reload()
    let first = try #require(monitor.report(for: .today))
    #expect(first.projectCount == 45 && first.projects.count == 20 && first.hasNext)
    await monitor.loadProjectPage(for: .today, direction: .next)
    let second = try #require(monitor.report(for: .today))
    #expect(second.totals == first.totals && second.projects.count == 20 && second.hasPrevious)
    #expect(Set(first.projects.map(\.id)).isDisjoint(with: Set(second.projects.map(\.id))))
    await monitor.loadProjectPage(for: .today, direction: .next)
    let third = try #require(monitor.report(for: .today))
    #expect(third.projects.count == 5 && !third.hasNext && third.totals.responses == 45)
    await monitor.loadProjectPage(for: .today, direction: .previous)
    #expect(monitor.report(for: .today)?.projects == second.projects)
    monitor.stop()
}

@Test @MainActor func projectIndexMonitorUnchangedPollKeepsPageAndNewSnapshotIsExplicitlyStale() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try indexScanWrite(root, name: "a.jsonl", text: (0..<45).map {
        indexScanClaude("r-\($0)", cwd: "/fixture/p-\($0)")
    }.joined())
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], now: { indexScanNow })
    await monitor.reload(); await monitor.loadProjectPage(for: .today, direction: .next)
    let browsed = try #require(monitor.report(for: .today))
    await monitor.reload()
    #expect(monitor.projectPageNumber(for: .today) == 2)
    #expect(monitor.report(for: .today)?.revision == browsed.revision)
    #expect(monitor.report(for: .today)?.projects == browsed.projects)
    #expect(!monitor.projectPageIsStale(for: .today))
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data(indexScanClaude("added", cwd: "/fixture/new").utf8)); try handle.close()
    await monitor.reload()
    #expect(monitor.projectPageNumber(for: .today) == 2)
    #expect(monitor.report(for: .today)?.projects == browsed.projects)
    #expect(monitor.report(for: .today)?.totals.responses == 46)
    #expect(monitor.projectPageIsStale(for: .today))
    monitor.refreshProjectList(for: .today)
    #expect(monitor.projectPageNumber(for: .today) == 1 && !monitor.projectPageIsStale(for: .today))
    monitor.stop()
}

@Test(arguments: [false, true]) @MainActor
func projectIndexMonitorKeepsCachedTotalsAfterWorkerErrorAndUnavailableReopen(_ unsupported: Bool) async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("logs")
    try indexScanWrite(source, name: "a.jsonl", text: indexScanClaude("one") +
        (unsupported ? "{\"type\":\"unknown_usage\"}\n" : ""))
    let url = root.appendingPathComponent("cache/index.sqlite")
    let fail = Mutex(false)
    let scanner = ProjectUsageScanner(indexURL: url, beforePass: {
        if fail.withLock({ $0 }) { throw CocoaError(.fileReadUnknown) }
    })
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: source], scanner: scanner, now: { indexScanNow })
    await monitor.reload()
    #expect(monitor.report(for: .today)?.totals.responses == 1)
    let originalWarning = monitor.warning
    #expect((originalWarning != nil) == unsupported)
    fail.withLock { $0 = true }; await monitor.reload()
    #expect(monitor.hasCachedUsage && monitor.progress.stale)
    #expect(monitor.report(for: .today)?.totals.responses == 1)
    #expect(monitor.warning != nil)
    let beforeRecovery = monitor.report(for: .today)?.revision
    fail.withLock { $0 = false }; await monitor.reload()
    #expect(monitor.log == .loaded && monitor.progress.ready)
    #expect(monitor.warning == originalWarning)
    #expect(monitor.report(for: .today)?.totals.responses == 1)
    #expect(monitor.report(for: .today)?.revision == beforeRecovery)
    monitor.stop(); await scanner.cancel()
    try FileManager.default.removeItem(at: source)
    try Data("not a directory".utf8).write(to: source)
    let reopened = ProjectUsageMonitor(roots: [.claudeCode: source], scanner: ProjectUsageScanner(indexURL: url), now: { indexScanNow })
    await reopened.reload()
    #expect(reopened.hasCachedUsage && reopened.progress.stale)
    #expect(reopened.report(for: .today)?.totals.responses == 1)
    #expect(reopened.warning != nil)
    reopened.stop()
}

@Test func projectIndexScannerProgressIsPerSourceAndCompletesColdFiles() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
    let claudeText = (0..<20).map { indexScanClaude("c-\($0)") }.joined()
    let codexText = "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-10-09T11:00:00Z\",\"payload\":{\"session_id\":\"codex\",\"response_id\":\"r\",\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}\n"
    try indexScanWrite(claude, name: "a.jsonl", text: claudeText)
    try indexScanWrite(codex, name: "rollout-a.jsonl", text: codexText)
    let scanner = ProjectUsageScanner()
    let report = try await indexScanDrain(scanner, roots: [.claudeCode: claude, .codex: codex])
    let c = try #require(report.progress.sources.first { $0.source == .claudeCode })
    let x = try #require(report.progress.sources.first { $0.source == .codex })
    #expect(c.completedFiles == 1 && x.completedFiles == 1)
    #expect(c.processedBytes == Int64(claudeText.utf8.count))
    #expect(x.processedBytes == Int64(codexText.utf8.count))
    #expect(c.processedBytes != x.processedBytes && report.progress.ready)
}

@Test func projectIndexScannerUnfinishedRecordIsNotReadyAndWaitsForNextPoll() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let partial = String(indexScanClaude("second").dropLast())
    let file = try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude("first") + partial)
    let scanner = ProjectUsageScanner()
    let publication = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(!publication.progress.ready)
    #expect(publication.warning?.contains("unfinished") == true)
    #expect(try indexScanToday(publication).totals.responses == 1)
    let waiting = try await scanner.scan(roots: [.claudeCode: root], now: indexScanNow, calendar: indexScanCalendar())
    #expect(!waiting.needsMoreWork && !waiting.progress.ready)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
    let complete = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(complete).totals.responses == 2)
    #expect(complete.progress.ready && complete.warning == nil)
}

@Test @MainActor func projectIndexMonitorSelectionChangeRejectsQueuedOldPageRequest() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    try indexScanWrite(root, name: "a.jsonl", text: (0..<45).map {
        indexScanClaude("r-\($0)", cwd: "/fixture/p-\($0)")
    }.joined())
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], now: { indexScanNow })
    await monitor.reload(); monitor.selectProjectReport(for: .today)
    let oldRequest = Task { await monitor.loadProjectPage(for: .today, direction: .next) }
    monitor.selectProjectReport(for: .month, source: .claudeCode)
    await oldRequest.value
    #expect(monitor.projectPageNumber(for: .today) == 1)
    monitor.selectProjectReport(for: .today)
    await monitor.loadProjectPage(for: .today, direction: .next)
    #expect(monitor.projectPageNumber(for: .today) == 2)
    monitor.selectProjectReport(for: .today, source: .codex)
    monitor.selectProjectReport(for: .today)
    #expect(monitor.projectPageNumber(for: .today) == 1)
    monitor.stop()
}

@Test(arguments: [false, true]) func projectIndexScannerNonregularReplacementRetiresOldUsage(_ fifo: Bool) async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude("old"))
    let scanner = ProjectUsageScanner()
    _ = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    try FileManager.default.removeItem(at: file)
    if fifo { #expect(mkfifo(file.path, 0o600) == 0) }
    else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
    let publication = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(publication).totals.responses == 0)
    #expect(publication.progress.ready)
}

@Test @MainActor func projectIndexMonitorSameDayClockRollbackAndFutureCatchupRecompute() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude("dated").replacingOccurrences(of: "11:00:00Z", with: "11:45:00Z"))
    let clock = Mutex(indexScanNow)
    let monitor = ProjectUsageMonitor(roots: [.claudeCode: root], now: { clock.withLock { $0 } })
    await monitor.reload(); #expect(monitor.report(for: .today)?.totals.responses == 1)
    clock.withLock { $0 = APIDateParser.parse("2026-10-09T11:30:00Z")! }
    await monitor.reload(); #expect(monitor.report(for: .today)?.totals.responses == 0)
    #expect(monitor.warning?.contains("Future-dated") == true)
    clock.withLock { $0 = indexScanNow }
    await monitor.reload(); #expect(monitor.report(for: .today)?.totals.responses == 1)
    monitor.stop()
}

@Test func projectIndexScannerAcceptsBounded4096ByteIdentityWithoutFailingPass() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    try indexScanWrite(root, name: "a.jsonl", text: indexScanClaude(String(repeating: "x", count: 4096)))
    let report = try await indexScanDrain(ProjectUsageScanner(), roots: [.claudeCode: root])
    #expect(try indexScanToday(report).totals.responses == 1)
    #expect(report.warning == nil)
}

@Test func projectIndexScannerLargeReportCleanupConvergesAndUnchangedPollKeepsRevision() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try indexScanWrite(root, name: "projects.jsonl", text: (0..<80).map {
        indexScanClaude("p-\($0)", cwd: "/fixture/project-\($0)")
    }.joined())
    var limits = ProjectUsageLimits(); limits.records = 8
    let scanner = ProjectUsageScanner(limits: limits)
    let first = try await indexScanDrain(scanner, roots: [.claudeCode: root], maxPasses: 500)
    #expect(try indexScanToday(first).projectCount == 80)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data(indexScanClaude("added", cwd: "/fixture/added").utf8)); try handle.close()
    let changed = try await indexScanDrain(scanner, roots: [.claudeCode: root], maxPasses: 500)
    let changedReport = try indexScanToday(changed)
    #expect(changedReport.projectCount == 81 && changedReport.totals.responses == 81)
    // Eight populated range/source reports yield640 old group rows, larger than one maintenance pass.
    let unchanged = try await indexScanDrain(scanner, roots: [.claudeCode: root], maxPasses: 500)
    #expect(try indexScanToday(unchanged).revision == changedReport.revision)
    #expect(try indexScanToday(unchanged).totals == changedReport.totals)
    #expect(await scanner.currentPublication()?.reports[.init(range: .today, source: nil)]?.revision == changedReport.revision)
    print("PROJECT_USAGE_FIXTURE cleanupProjects=81 budgetRows=8 converged=true unchangedRevision=true")
}

@Test(arguments: [1, 2]) func projectIndexScannerFewGiantFilesUseRemainingByteBudget(_ files: Int) async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let body = String(repeating: "x", count: 4 * 1024 * 1024)
    for id in 0..<files {
        try indexScanWrite(root, name: "\(id).jsonl", text: "{\"type\":\"user\",\"content\":\"\(body)\"}\n" + indexScanClaude("tail-\(id)"))
    }
    var limits = ProjectUsageLimits(); limits.bytes = 256 * 1024
    let scanner = ProjectUsageScanner(limits: limits)
    for _ in 0..<2 {
        let before = await scanner.streamedBytes
        let result = try await scanner.scan(roots: [.claudeCode: root], now: indexScanNow, calendar: indexScanCalendar())
        let delta = await scanner.streamedBytes - before
        #expect(delta == limits.bytes) // Previously one/two files consumed only64/128KiB per pass.
        #expect(result.needsMoreWork)
    }
    let complete = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(complete).totals.responses == files)
    print("PROJECT_USAGE_FIXTURE tailFiles=\(files) bytesPerPass=262144 converged=true")
}

/// Regression for saturated resident slots: every bounded pass must still advance useful file work.
@Test func projectIndexScannerActiveSlotsDoNotWaitForWholeBacklogQueue() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let body = String(repeating: "x", count: 512 * 1024)
    for id in 0..<96 {
        let usage = indexScanClaude("large-\(id)")
        let text = id.isMultiple(of: 2)
            ? "{\"type\":\"user\",\"content\":\"\(body)\"}\n" + usage
            : usage.replacingOccurrences(of: "\"id\":\"large-\(id)\",", with: "\"content\":\"\(body)\",\"id\":\"large-\(id)\",")
        try indexScanWrite(root, name: "\(id).jsonl", text: text)
    }
    let scanner = ProjectUsageScanner()
    let initialBytes = await scanner.streamedBytes
    for _ in 0..<4 {
        let before = await scanner.streamedBytes
        let result = try await scanner.scan(roots: [.claudeCode: root], now: indexScanNow, calendar: indexScanCalendar())
        let delta = await scanner.streamedBytes - before
        #expect(delta >= 1024 * 1024) // Old slot-full queue rotation had zero-byte passes here.
        #expect(result.needsMoreWork)
    }
    let firstFourBytes = await scanner.streamedBytes - initialBytes
    let complete = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(complete).totals.responses == 96)
    #expect(complete.progress.ready && complete.warning == nil)
    print("PROJECT_USAGE_FIXTURE activeSlotFiles=96 firstFourPassBytes=\(firstFourBytes) responses=96")
}

@Test func projectIndexScannerTransientProbeAndPartialEOFFreeSlotsForNewFiles() async throws {
    let root = try indexScanTemp(); defer { try? FileManager.default.removeItem(at: root) }
    let body = String(repeating: "x", count: 512 * 1024)
    let giant = try indexScanWrite(root, name: "large.jsonl", text: "{\"type\":\"user\",\"content\":\"\(body)")
    try indexScanWrite(root, name: "small.jsonl", text: indexScanClaude("small"))
    var limits = ProjectUsageLimits(); limits.residentBytes = 512 * 1024; limits.files = 2; limits.bytes = 128 * 1024
    let scanner = ProjectUsageScanner(limits: limits)
    let first = try await scanner.scan(roots: [.claudeCode: root], now: indexScanNow, calendar: indexScanCalendar())
    #expect(first.publication?.reports[.init(range: .today, source: nil)]?.totals.responses == 1)
    let partial = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(!partial.progress.ready && partial.warning?.contains("unfinished") == true)
    try indexScanWrite(root, name: "new.jsonl", text: indexScanClaude("new"))
    let withNewFile = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(withNewFile).totals.responses == 2)
    let handle = try FileHandle(forWritingTo: giant); try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\"}\n" + indexScanClaude("giant-complete")).utf8)); try handle.close()
    let finished = try await indexScanDrain(scanner, roots: [.claudeCode: root])
    #expect(try indexScanToday(finished).totals.responses == 3)
    #expect(finished.progress.ready && finished.warning == nil)
}

/// Explicitly opt-in, read-only producer validation. The normal suite returns before touching real roots.
@Test func projectUsageLiveReadOnlyTemporaryIndexVerification() async throws {
    guard ProcessInfo.processInfo.environment["PROJECT_USAGE_LIVE_VERIFY"] == "1" else { return }
    let temporary = try indexScanTemp()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots: [ProjectUsageSource: URL] = [
        .claudeCode: home.appendingPathComponent(".claude/projects"),
        .codex: home.appendingPathComponent(".codex/sessions")
    ]
    let url = temporary.appendingPathComponent("private-cache/index.sqlite")
    let now = Date(), calendar = Calendar.autoupdatingCurrent
    let clock = ContinuousClock(), started = clock.now
    let deadline = started.advanced(by: .seconds(600))
    func elapsed() -> Int { Int(started.duration(to: clock.now).components.seconds) }
    func warningCategories(_ warning: String?) -> String {
        guard let warning else { return "none" }
        let checks: [(String, String)] = [("Malformed", "malformed"), ("unsupported", "unsupported"),
            ("Unsupported", "unsupported"), ("unreadable", "unreadable"), ("unavailable", "unavailable"),
            ("missing", "missing"), ("unfinished", "unfinished"), ("overflow", "overflow"),
            ("Future-dated", "future"), ("Conflicting", "conflicting"), ("ambiguous", "ambiguous"),
            ("inconsistent", "inconsistent"), ("index incomplete", "index_incomplete")]
        return Set(checks.filter { warning.contains($0.0) }.map(\.1)).sorted().joined(separator: ",")
    }
    func totals(_ publication: ProjectUsagePublication) -> [ProjectUsageReportKey: ProjectUsageTotals] {
        publication.reports.mapValues(\.totals)
    }
    func drain(_ scanner: ProjectUsageScanner, phase: String, roots: [ProjectUsageSource: URL]) async throws
        -> (ProjectUsagePublication?, ProjectUsageProgress, Int, Bool) {
        var publication: ProjectUsagePublication?, progress = ProjectUsageProgress(), passes = 0
        while clock.now < deadline {
            let result = try await scanner.scan(roots: roots, now: now, calendar: calendar)
            passes += 1; progress = result.progress
            if let update = result.publication { publication = update }
            if passes % 100 == 0 {
                let files = progress.sources.map { "\($0.source.rawValue)=\($0.discoveredFiles)" }.joined(separator: ",")
                let indexedBytes = progress.sources.reduce(Int64(0)) { $0 + $1.processedBytes }
                let completedFiles = progress.sources.reduce(0) { $0 + $1.completedFiles }
                print("PROJECT_USAGE_VERIFY phase=\(phase) passes=\(passes) sourceFiles=\(files) completedFiles=\(completedFiles) indexedBytes=\(indexedBytes) parseBytes=\(await scanner.streamedBytes) verifyBytes=\(await scanner.verifiedReadBytes()) rawPending=\(result.rawPending) maintenancePending=\(result.maintenancePending) publicationPending=\(result.publicationPending) elapsedSeconds=\(elapsed())")
            }
            if !result.needsMoreWork {
                if publication == nil { publication = await scanner.currentPublication() }
                return (publication, progress, passes, true)
            }
            await Task.yield()
        }
        return (publication, progress, passes, false)
    }
    let coldScanner = ProjectUsageScanner(indexURL: url)
    let cold = try await drain(coldScanner, phase: "cold", roots: roots)
    let coldDone = cold.3
    #expect(coldDone)
    guard coldDone, let coldPublication = cold.0 else { return }
    let files = cold.1.sources.map { "\($0.source.rawValue)=\($0.discoveredFiles)" }.joined(separator: ",")
    let coldTotals = coldPublication.reports[.init(range: .halfYear, source: nil)]?.totals ?? .init()
    print("PROJECT_USAGE_VERIFY phase=cold_complete passes=\(cold.2) sourceFiles=\(files) parseBytes=\(await coldScanner.streamedBytes) verifyBytes=\(await coldScanner.verifiedReadBytes()) ready=\(cold.1.ready) responses6m=\(coldTotals.responses) input6m=\(coldTotals.inputTokens) output6m=\(coldTotals.outputTokens) warnings=\(warningCategories(coldPublication.warning)) elapsedSeconds=\(elapsed())")
    await coldScanner.cancel()
    // First replay the exact captured index, without discovering newer producer appends.
    let warmScanner = ProjectUsageScanner(indexURL: url)
    let cached = try await drain(warmScanner, phase: "cache_reopen", roots: [:])
    let cachedDone = cached.3
    #expect(cachedDone)
    guard cachedDone, let cachedPublication = cached.0 else { return }
    let sameCapturedTotals = totals(cachedPublication) == totals(coldPublication)
    #expect(sameCapturedTotals)
    let cachedReadBytes = await warmScanner.streamedBytes
    #expect(cachedReadBytes == 0)
    print("PROJECT_USAGE_VERIFY phase=cache_reopen passes=\(cached.2) parseBytes=\(cachedReadBytes) capturedTotalsStable=\(sameCapturedTotals) elapsedSeconds=\(elapsed())")
    // Then run a normal warm poll; any active append is validated as a later finite target.
    let warm = try await drain(warmScanner, phase: "warm_poll", roots: roots)
    let warmDone = warm.3
    #expect(warmDone)
    guard warmDone, let warmPublication = warm.0 else { return }
    let parsed = await warmScanner.streamedBytes, verified = await warmScanner.verifiedReadBytes()
    let stable = totals(warmPublication) == totals(coldPublication)
    if parsed == 0 && verified == 0 { #expect(stable) }
    print("PROJECT_USAGE_VERIFY phase=warm_complete passes=\(warm.2) parseBytes=\(parsed) verifyBytes=\(verified) ready=\(warm.1.ready) unchangedCapturedTotals=\(stable) warnings=\(warningCategories(warmPublication.warning)) elapsedSeconds=\(elapsed())")
    await warmScanner.cancel()
}
