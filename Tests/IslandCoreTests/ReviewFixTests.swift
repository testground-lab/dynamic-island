import Foundation
import Testing

@testable import IslandCore

private func reviewClient(_ transport: StubTransport) -> ManagementClient {
    ManagementClient(
        baseURL: URL(string: BaseURLValidator.defaultBaseURL)!, key: "fake-review-key",
        transport: transport)
}

@Test func drainPreservesPoppedRecordsWhenLaterBatchFails() async throws {
    let first = StubTransport.Reply.response(200, Data(#"[{"model":"saved"}]"#.utf8))
    for failure in [
        StubTransport.Reply.failure(.timedOut), .response(500, Data()),
        .response(200, Data("broken-json".utf8)),
    ] {
        let result = try await reviewClient(StubTransport([first, failure])).drainUsageQueueResult(
            batchSize: 1)
        #expect(result.records.map(\.model) == ["saved"])
        #expect(result.available)
    }
    let unavailable = try await reviewClient(StubTransport([first, .response(404, Data())]))
        .drainUsageQueueResult(batchSize: 1)
    #expect(unavailable.records.map(\.model) == ["saved"])
    #expect(!unavailable.available)
    do {
        _ = try await reviewClient(StubTransport([.response(500, Data())])).drainUsageQueueResult()
        Issue.record("First-batch errors must throw")
    } catch {
        #expect(error as? ManagementError == .http(500))
    }
}

@Test(arguments: [301, 302, 303, 307, 308])
func redirectsAreHTTPErrors(_ status: Int) async {
    do {
        _ = try await reviewClient(StubTransport([.response(status, Data())])).authFiles()
        Issue.record("Expected redirect rejection")
    } catch {
        #expect(error as? ManagementError == .http(status))
    }
}

private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> UInt8? {
        lock.withLock {
            count += 1
            return count <= 100 ? 1 : nil
        }
    }
    var consumed: Int { lock.withLock { count } }
}

@Test func streamStopsAtResponseLimit() async throws {
    let counter = StreamCounter()
    let stream = AsyncStream<UInt8>(unfolding: { counter.next() })
    do {
        _ = try await URLSession.boundedData(from: stream, limit: 4)
        Issue.record("Expected streaming size limit")
    } catch {
        #expect(error as? ManagementError == .responseTooLarge)
    }
    #expect(counter.consumed == 5)
    let exact = AsyncStream<UInt8> { continuation in
        for byte in [UInt8(1), 2, 3, 4] { continuation.yield(byte) }
        continuation.finish()
    }
    #expect(try await URLSession.boundedData(from: exact, limit: 4) == Data([1, 2, 3, 4]))
}

@Test func oversizedStubResponseIsRejected() async {
    let data = Data(repeating: 0, count: URLSession.islandResponseLimit + 1)
    do {
        _ = try await reviewClient(StubTransport([.response(200, data)])).authFiles()
        Issue.record("Expected oversized response rejection")
    } catch {
        #expect(error as? ManagementError == .responseTooLarge)
        #expect(!String(describing: error).contains("fake-review-key"))
    }
}

@Test func usageTimestampAndModelBounds() async {
    let now = Fixtures.referenceNow
    let aggregator = UsageAggregator(persistenceURL: nil, now: { now })
    await aggregator.ingest([
        UsageRecord(timestamp: now.addingTimeInterval(86400), model: "future"),
        UsageRecord(timestamp: now.addingTimeInterval(-48 * 3600 - 1), model: "too-old"),
        UsageRecord(model: String(repeating: "x", count: 100)),
        UsageRecord(model: String(repeating: "x", count: 64) + "different"),
    ])
    let summary = await aggregator.summary(now: now)
    #expect(summary.lastHour.first { $0.model == "future" }?.requests == 1)
    #expect(!summary.today.contains { $0.model == "too-old" })
    #expect(summary.lastHour.first { $0.model == String(repeating: "x", count: 64) }?.requests == 2)
    #expect(summary.today.allSatisfy { $0.model.count <= 64 })
}

@Test func usageModelCardinalityIsCappedAndOverflowIsCounted() async {
    let now = Fixtures.referenceNow
    let aggregator = UsageAggregator(persistenceURL: nil, now: { now })
    await aggregator.ingest(
        (0..<70).map { UsageRecord(model: "model-\($0)", tokens: UsageTokens(totalTokens: 10)) })
    let summary = await aggregator.summary(now: now)
    #expect(summary.lastHour.count == 50)
    #expect(summary.lastHour.first { $0.model == "other" }?.requests == 21)
    #expect(summary.lastHour.reduce(0) { $0 + $1.requests } == 70)
    #expect(summary.lastHour.reduce(0) { $0 + $1.totalTokens } == 700)
    await aggregator.ingest([
        UsageRecord(model: "model-0"), UsageRecord(model: "another-new-model"),
    ])
    let next = await aggregator.summary(now: now)
    #expect(next.lastHour.count == 50)
    #expect(next.lastHour.first { $0.model == "model-0" }?.requests == 2)
    #expect(next.lastHour.first { $0.model == "other" }?.requests == 22)
}

@Test func unchangedUsageDoesNotRewritePersistence() async throws {
    let now = Fixtures.referenceNow
    let directory = URL(
        fileURLWithPath: "/Users/ksotis/workspace/tools/dynamic-island/.build/core-review-tests/"
            + UUID().uuidString)
    let url = directory.appendingPathComponent("usage.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let aggregator = UsageAggregator(persistenceURL: url, now: { now })
    await aggregator.ingest([UsageRecord(model: "kept")])
    let initial =
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    let originalData = try Data(contentsOf: url)
    await aggregator.ingest([])
    await aggregator.ingest([
        UsageRecord(timestamp: now.addingTimeInterval(-49 * 3600), model: "ignored")
    ])
    #expect(
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            == initial)
    #expect(try Data(contentsOf: url) == originalData)
    let reloaded = UsageAggregator(persistenceURL: url, now: { now })
    #expect(await reloaded.summary(now: now) == aggregator.summary(now: now))
    await aggregator.reset()
    let resetInode =
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    await aggregator.reset()
    #expect(
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            == resetInode)
}

@Test func liveRequestsHaveFixedURLsAndOptionalCodexAccountID() throws {
    let response = try JSONDecoder().decode(
        AuthFilesResponse.self, from: Fixtures.data("auth-files"))
    let claude = LiveQuotaFetcher.request(for: response.files[0])
    var codexFile = response.files[2]
    codexFile.idToken = nil
    let codex = LiveQuotaFetcher.request(for: codexFile)
    #expect(claude?.url == "https://api.anthropic.com/api/oauth/usage")
    #expect(codex?.url == "https://chatgpt.com/backend-api/wham/usage")
    #expect(codex?.header["Chatgpt-Account-Id"] == nil)
    #expect(
        Set(response.files.compactMap { LiveQuotaFetcher.request(for: $0)?.url }) == [
            "https://api.anthropic.com/api/oauth/usage",
            "https://chatgpt.com/backend-api/wham/usage",
        ])
}

@Test(arguments: [
    "http://127.0.0.1.evil.com", "http://localhost@evil.com", "http://user:pw@127.0.0.1:8317",
    "http://localhost.", "http://0.0.0.0:8317", "http://127.1:8317",
    "http://[::ffff:127.0.0.1]:8317",
    "http://127.0.0.1:8317/v0", "http://127.0.0.1:8317?x=1", "ftp://127.0.0.1",
])
func baseURLBypassProbesAreRejected(_ string: String) {
    #expect(BaseURLValidator.validate(string) == nil)
}
