import Foundation
import Testing

@testable import IslandCore

private let now = Fixtures.referenceNow
private func temporaryPersistence() throws -> URL {
    let dir = URL(
        fileURLWithPath: "/Users/ksotis/workspace/tools/dynamic-island/.build/core-tests/"
            + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("usage.json")
}
private func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

@Test func usageHourDayBoundariesAndFallbacks() async {
    let a = UsageAggregator(persistenceURL: nil, calendar: utcCalendar(), now: { now })
    let start = utcCalendar().startOfDay(for: now)
    await a.ingest([
        UsageRecord(
            timestamp: now.addingTimeInterval(-3600), model: "boundary",
            tokens: UsageTokens(totalTokens: 500)),
        UsageRecord(
            timestamp: now.addingTimeInterval(-3540), model: "recent", failed: true,
            tokens: UsageTokens(
                inputTokens: 10, outputTokens: 20, reasoningTokens: 5, totalTokens: 0)),
        UsageRecord(timestamp: start, model: "midnight", tokens: UsageTokens(totalTokens: 100)),
        UsageRecord(
            timestamp: start.addingTimeInterval(-60), model: "yesterday",
            tokens: UsageTokens(totalTokens: 100)),
        UsageRecord(
            model: "", alias: "alias",
            tokens: UsageTokens(inputTokens: 7, outputTokens: 3, totalTokens: 2)),
        UsageRecord(tokens: UsageTokens(inputTokens: -10, outputTokens: 5)),
    ])
    let summary = await a.summary(now: now)
    #expect(summary.lastHour.map(\.model) == ["recent", "unknown", "alias"])
    #expect(summary.lastHour[0].totalTokens == 35)
    #expect(summary.lastHour[0].failed == 1)
    #expect(summary.lastHour[2].totalTokens == 2)
    #expect(summary.today.contains { $0.model == "midnight" })
    #expect(!summary.today.contains { $0.model == "yesterday" })
    #expect(summary.trackingSince == now)
}
@Test func usageFixturesAndSorting() async throws {
    let records = try JSONDecoder().decode(UsageQueueBatch.self, from: Fixtures.data("usage-queue"))
        .records
    let a = UsageAggregator(persistenceURL: nil, now: { now })
    await a.ingest(records)
    let summary = await a.summary(now: now)
    #expect(summary.lastHour.reduce(0) { $0 + $1.requests } == 6)
    #expect(summary.today.reduce(0) { $0 + $1.requests } == 12)
    #expect(summary.today.reduce(0) { $0 + $1.failed } == 2)
    #expect(summary.lastHour.first?.model == "gemini-2.5-pro")
    let b = UsageAggregator(persistenceURL: nil, now: { now })
    await b.ingest([
        UsageRecord(model: "z", tokens: UsageTokens(totalTokens: 1)),
        UsageRecord(model: "a", tokens: UsageTokens(totalTokens: 1)), UsageRecord(model: "many"),
        UsageRecord(model: "many", tokens: UsageTokens(totalTokens: 1)),
    ])
    #expect(await b.summary(now: now).lastHour.map(\.model) == ["many", "a", "z"])
}
@Test func usagePersistencePruningResetAndPrivacy() async throws {
    let url = try temporaryPersistence()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let a = UsageAggregator(persistenceURL: url, calendar: utcCalendar(), now: { now })
    await a.ingest([
        UsageRecord(timestamp: now.addingTimeInterval(-49 * 3600), model: "pruned"),
        UsageRecord(timestamp: now.addingTimeInterval(-47 * 3600), model: "retained"),
        UsageRecord(model: "current", failed: true, tokens: UsageTokens(totalTokens: 123)),
    ])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("pruned"))
    #expect(text.contains("retained"))
    #expect(!text.contains("auth_index"))
    #expect(!text.contains("provider"))
    let b = UsageAggregator(persistenceURL: url, calendar: utcCalendar(), now: { now })
    #expect(await a.summary(now: now) == b.summary(now: now))
    await b.reset()
    #expect(await b.summary(now: now) == .empty)
    let c = UsageAggregator(persistenceURL: url, now: { now })
    #expect(await c.summary(now: now) == .empty)
}
@Test func corruptPersistenceIgnored() async throws {
    let url = try temporaryPersistence()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("not-json".utf8).write(to: url)
    let a = UsageAggregator(persistenceURL: url)
    #expect(await a.summary(now: now) == .empty)
}

actor StubTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
        case reflectedFailure(String)
    }
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? Reply.response(200, Data("[]".utf8)) : replies.removeFirst()
        switch reply {
        case .response(let status, let data):
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
            )
        case .failure(let code): throw URLError(code)
        case .reflectedFailure(let text):
            throw NSError(domain: text, code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
    func captured() -> [URLRequest] { requests }
}
private func client(_ stub: StubTransport, key: String = "test-secret-never-log")
    -> ManagementClient
{
    ManagementClient(
        baseURL: URL(string: BaseURLValidator.defaultBaseURL)!, key: key, transport: stub)
}
@Test(arguments: [401, 403]) func authorizationFailures(_ status: Int) async {
    do {
        _ = try await client(StubTransport([.response(status, Data())])).authFiles()
        Issue.record("Expected rejection")
    } catch {
        #expect(error as? ManagementError == .unauthorized)
        #expect(!String(describing: error).contains("test-secret-never-log"))
    }
}
@Test(arguments: [
    URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
    .cannotFindHost,
])
func networkFailures(_ code: URLError.Code) async {
    do {
        _ = try await client(StubTransport([.failure(code)])).authFiles()
        Issue.record("Expected network failure")
    } catch {
        if case .proxyDown = error as? ManagementError {
        } else {
            Issue.record("Expected proxyDown")
        }
        #expect(!String(describing: error).contains("test-secret-never-log"))
    }
}
@Test func errorsNeverReflectKeyOrBody() async {
    let secret = "test-secret-never-log"
    for reply in [
        StubTransport.Reply.reflectedFailure(secret), .response(500, Data(secret.utf8)),
        .response(200, Data(secret.utf8)),
    ] {
        do {
            _ = try await client(StubTransport([reply]), key: secret).authFiles()
            Issue.record("Expected error")
        } catch { #expect(!String(describing: error).contains(secret)) }
    }
}
@Test func usageUnavailable() async throws {
    let result = try await client(StubTransport([.response(404, Data())])).drainUsageQueueResult()
    #expect(!result.available)
    #expect(result.records.isEmpty)
    #expect(
        try await client(StubTransport([.response(404, Data())])).drainUsageQueueResult().records
            .isEmpty)
}
@Test func drainLoopCountsJunkAndStops() async throws {
    let stub = StubTransport([
        .response(200, Data(#"[{"model":"one"},"junk"]"#.utf8)),
        .response(200, Data(#"[{"model":"two"}]"#.utf8)),
    ])
    let records = try await client(stub).drainUsageQueueResult(batchSize: 2).records
    #expect(records.map(\.model) == ["one", "two"])
    let requests = await stub.captured()
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/v0/management/usage-queue")
    #expect(requests[0].url?.query == "count=2")
    #expect(
        requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-secret-never-log")
}
@Test func drainBoundedAndEmpty() async throws {
    let stub = StubTransport(
        Array(repeating: .response(200, Data(#"[{"model":"m"}]"#.utf8)), count: 4))
    #expect(
        try await client(stub).drainUsageQueueResult(batchSize: 1, maxBatches: 2).records.count == 2
    )
    #expect(await stub.captured().count == 2)
    let empty = StubTransport([.response(200, Data("[]".utf8))])
    #expect(try await client(empty).drainUsageQueueResult().records.isEmpty)
    #expect(await empty.captured().count == 1)
}
@Test func authAndAPICallWireRequests() async throws {
    let stub = StubTransport([
        .response(200, Fixtures.data("auth-files")),
        .response(200, Fixtures.data("api-call-claude-usage")),
    ])
    let c = client(stub)
    #expect(try await c.authFiles().files.count == 5)
    let request = APICallRequest(
        authIndex: "fake-index", url: "https://example.com",
        header: ["Authorization": "Bearer $TOKEN$"])
    #expect(try await c.apiCall(request).statusCode == 200)
    let requests = await stub.captured()
    #expect(requests[0].url?.path == "/v0/management/auth-files")
    #expect(requests[1].url?.path == "/v0/management/api-call")
    #expect(requests[1].httpMethod == "POST")
    #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(String(decoding: requests[1].httpBody!, as: UTF8.self).contains("auth_index"))
}
@Test func invalidClientBaseURL() async {
    let c = ManagementClient(
        baseURL: URL(string: "http://example.com")!, key: "secret", transport: StubTransport([]))
    do {
        _ = try await c.authFiles()
        Issue.record("Expected invalid URL")
    } catch { #expect(error as? ManagementError == .invalidBaseURL) }
}
@Test func ephemeralSessionConfiguration() {
    let c = URLSession.islandEphemeral.configuration
    #expect(c.urlCache == nil)
    #expect(c.httpCookieStorage == nil)
    #expect(!c.httpShouldSetCookies)
    #expect(c.timeoutIntervalForRequest == 8)
    #expect(c.timeoutIntervalForResource == 20)
}
