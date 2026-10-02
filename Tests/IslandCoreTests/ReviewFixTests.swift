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
