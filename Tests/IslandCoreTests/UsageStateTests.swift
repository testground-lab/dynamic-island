import Foundation
import Testing
@testable import IslandCore

private func report(requests: Int) -> UsageReport {
    UsageReport(range: .today, start: Date(timeIntervalSince1970: 0),
                totals: UsageTotals(requests: requests, failed: 0, inputTokens: 10, outputTokens: 5, totalTokens: 15))
}

@Test func usageStateExplainsMissingKeyFirst() {
    let state = UsageState.resolve(connection: .needsKey, usageAvailable: true, queueError: nil, report: nil)
    #expect(state == .needsKey)
    #expect(state.message?.contains("management key in Settings") == true)
}

@Test func usageStateForRejectedKeyAndDownProxy() {
    #expect(UsageState.resolve(connection: .keyRejected, usageAvailable: true, queueError: nil, report: nil) == .keyRejected)
    #expect(UsageState.resolve(connection: .proxyDown("x"), usageAvailable: true, queueError: nil, report: nil) == .proxyUnreachable)
    // History recorded earlier stays visible while the proxy is down.
    #expect(UsageState.resolve(connection: .proxyDown("x"), usageAvailable: true, queueError: nil,
                               report: report(requests: 3)) == .data)
}

@Test func usageStateForQueueProblems() {
    let now = Date()
    let unavailable = UsageState.resolve(connection: .connected(at: now), usageAvailable: false, queueError: nil, report: report(requests: 0))
    #expect(unavailable == .queueUnavailable)
    #expect(unavailable.message?.contains("404") == true)
    let failed = UsageState.resolve(connection: .connected(at: now), usageAvailable: true, queueError: "HTTP 500", report: nil)
    #expect(failed == .queueError("HTTP 500"))
    #expect(failed.message == "Couldn't read the usage queue: HTTP 500.")
}

@Test func usageStateEmptyWaitingAndData() {
    let now = Date()
    #expect(UsageState.resolve(connection: .connected(at: now), usageAvailable: true, queueError: nil, report: nil) == .waiting)
    let empty = UsageState.resolve(connection: .connected(at: now), usageAvailable: true, queueError: nil, report: report(requests: 0))
    #expect(empty == .empty)
    #expect(empty.message?.contains("No requests in this range yet") == true)
    let data = UsageState.resolve(connection: .connected(at: now), usageAvailable: true, queueError: nil, report: report(requests: 2))
    #expect(data == .data)
    #expect(data.message == nil)
}

@MainActor @Test func modelUsageStateWithoutKeyIsNeedsKey() {
    let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: VolatileDefaults(), store: UsageStore(url: nil))
    #expect(model.usageState(for: .today) == .needsKey)
}

@MainActor @Test func modelRecordsQueueErrorButStillLoadsAccounts() async {
    let stub = StubTransport([.response(500, Data()), .response(200, Fixtures.data("auth-files"))])
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(keyStore: InMemoryKeyStore(key: "test"), defaults: defaults, store: UsageStore(url: nil),
                            clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    model.start()
    for _ in 0..<1000 where model.lastUpdated == nil { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(!model.accounts.isEmpty)
    #expect(model.usageQueueError == "HTTP 500")
    #expect(model.usageState(for: .today) == .queueError("HTTP 500"))
    model.stop()
}

@Test func storeFileIsCreatedEagerly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("usage.sqlite")
    _ = UsageStore(url: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func recordedHistoryWinsOverCurrentProblems() {
    let history = report(requests: 3)
    for connection: ConnectionState in [.keyRejected, .proxyDown("x"), .failed("HTTP 500"), .connected(at: Date())] {
        #expect(UsageState.resolve(connection: connection, usageAvailable: false, queueError: "HTTP 500",
                                   report: history) == .data)
    }
}

@Test func failedPollIsNotReportedAsEmpty() {
    let state = UsageState.resolve(connection: .failed("HTTP 500"), usageAvailable: true, queueError: nil,
                                   report: report(requests: 0))
    #expect(state == .pollFailed("HTTP 500"))
    #expect(state.message?.contains("HTTP 500") == true)
}

@Test func issueIsNilWhenEverythingWorks() {
    #expect(UsageState.issue(connection: .connected(at: Date()), usageAvailable: true, queueError: nil) == nil)
    #expect(UsageState.issue(connection: .connected(at: Date()), usageAvailable: false, queueError: nil) == .queueUnavailable)
}

@MainActor @Test func changingProxyClearsCachedQueueStatus() async {
    let stub = StubTransport([.response(404, Data()), .response(200, Fixtures.data("auth-files"))])
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(keyStore: InMemoryKeyStore(key: "test"), defaults: defaults, store: UsageStore(url: nil),
                            clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    model.start()
    for _ in 0..<1000 where model.lastUpdated == nil { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(!model.usageAvailable)
    model.stop()
    #expect(model.applyBaseURL("http://localhost:8317"))
    #expect(model.usageAvailable)
    #expect(model.usageQueueError == nil)
    model.stop()
}
