import Foundation
import Testing

@testable import IslandCore

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
