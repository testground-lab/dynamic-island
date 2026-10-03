import Foundation
import Testing

@testable import IslandCore

@Test func claudeOverageSignalsDoNotCreateLimitsOrWindows() throws {
    let data = Data(
        #"{"files":[{"id":"fake-pro","provider":"claude","quota":{"signals":{"Anthropic-Ratelimit-Unified-Status":"allowed","Anthropic-Ratelimit-Unified-5h-Utilization":"0.42","Anthropic-Ratelimit-Unified-7d-Utilization":"0.18","Anthropic-Ratelimit-Unified-7d-opus-Utilization":"0.2","Anthropic-Ratelimit-Unified-Overage-Status":"rejected","Anthropic-Ratelimit-Unified-Overage-Reset":"1790950000","Anthropic-Ratelimit-Unified-Overage-Period-Monthly-Utilization":"1","Anthropic-Ratelimit-Unified-7d_overage-Status":"rejected","Anthropic-Ratelimit-Unified-7d_overage-Utilization":"1","Anthropic-Ratelimit-Unified-2h-Utilization":"1"}}}]}"#
            .utf8)
    let response = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
    let account = AccountMapper.accounts(from: response, live: [:], now: Fixtures.referenceNow)[0]
    #expect(account.health == .ok)
    #expect(account.windows.map(\.id) == ["claude.5h", "claude.7d", "claude.7d_opus"])
    #expect(account.bindingWindow?.id == "claude.5h")
    var rejected = response
    rejected.files[0].quota?.signals["Anthropic-Ratelimit-Unified-7d-opus-Status"] = "rejected"
    #expect(
        AccountMapper.accounts(from: rejected, live: [:], now: Fixtures.referenceNow)[0].health
            == .rateLimited(until: nil, reason: "limit reached"))
}

@MainActor private func waitForState(_ predicate: () -> Bool) async {
    for _ in 0..<1000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("State transition timed out")
}

@MainActor @Test func usageQueueFailureDoesNotPreventAccountPolling() async {
    let stub = StubTransport([.response(500, Data()), .response(200, Fixtures.data("auth-files"))])
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake"), defaults: defaults,
        store: UsageStore(url: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    model.start()
    await waitForState { model.lastUpdated != nil }
    if case .connected = model.connection {
    } else {
        Issue.record("Expected account polling success")
    }
    #expect(model.usageAvailable)
    #expect(await stub.captured().count == 2)
    model.stop()
}

@MainActor @Test(arguments: [false, true])
func failedQueueKeepsPriorUsageAvailabilityAndSummary(_ available: Bool) async {
    let stub = StubTransport([
        .response(available ? 200 : 404, available ? Fixtures.data("usage-queue") : Data()),
        .response(200, Fixtures.data("auth-files")),
        .response(500, Data()), .response(200, Fixtures.data("auth-files")),
    ])
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "liveQuotaEnabled")
    let start = Date()
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake"), defaults: defaults,
        store: UsageStore(url: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) },
        now: { Fixtures.referenceNow.addingTimeInterval(Date().timeIntervalSince(start)) })
    model.start()
    await waitForState { model.lastUpdated != nil }
    let usage = model.usageReports
    let previous = model.lastUpdated
    model.refreshNow()
    await waitForState { model.lastUpdated != previous }
    #expect(model.usageAvailable == available)
    #expect(model.usageReports == usage)
    if available { #expect(usage[.today]?.byModel.count == 3) }
    if case .connected = model.connection {
    } else {
        Issue.record("Expected successful account polling")
    }
    model.stop()
}

@MainActor @Test func settingsChangesImmediatelyShowConnecting() throws {
    let transport = StubTransport([])
    let model = IslandModel(
        keyStore: InMemoryKeyStore(), defaults: VolatileDefaults(),
        store: UsageStore(url: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: transport) })
    #expect(model.connection == .needsKey)
    try model.saveKey("fake")
    #expect(model.connection == .connecting)
    model.stop()
    #expect(model.applyBaseURL("http://localhost:8317"))
    #expect(model.connection == .connecting)
    model.stop()
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Fixtures.referenceNow
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor FailingLiveTransport: HTTPTransport {
    private var calls = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        switch request.url!.lastPathComponent {
        case "auth-files":
            data = Data(
                #"{"files":[{"id":"fake-one","auth_index":"fake-one","provider":"claude"}]}"#.utf8)
        case "api-call":
            calls += 1
            data = Fixtures.data(calls == 1 ? "api-call-claude-usage" : "api-call-error")
        default:
            data = Data("[]".utf8)
        }
        return (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    func liveCallCount() -> Int { calls }
}

@MainActor @Test func failedLiveRefreshRetainsStillFreshQuota() async {
    let transport = FailingLiveTransport()
    let clock = TestClock()
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake"), defaults: VolatileDefaults(),
        store: UsageStore(url: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: transport) },
        now: { clock.now() })
    model.start()
    await waitForState { model.accounts.first?.windows.count == 3 }
    let windows = model.accounts.first?.windows
    let source = model.accounts.first?.quotaSource
    clock.advance(301)
    model.refreshNow()
    await waitForState { model.lastUpdated == clock.now() }
    for _ in 0..<1000 {
        if await transport.liveCallCount() == 2 { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    try? await Task.sleep(for: .milliseconds(10))
    #expect(await transport.liveCallCount() == 2)
    #expect(model.accounts.first?.windows == windows)
    #expect(model.accounts.first?.quotaSource == source)
    model.stop()
}

@Test(arguments: [
    URLError.Code.secureConnectionFailed, .serverCertificateHasBadDate,
    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
    .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
])
func tlsFailuresAreNotProxyDown(_ code: URLError.Code) async {
    let client = ManagementClient(
        baseURL: URL(string: "https://example.com")!, key: "fake-secret",
        transport: StubTransport([.failure(code)]))
    do {
        _ = try await client.authFiles()
        Issue.record("Expected TLS error")
    } catch {
        #expect(error as? ManagementError == .tls)
        #expect(!String(describing: error).contains("fake-secret"))
    }
}

@MainActor @Test func tlsFailureShowsTLSState() async {
    let transport = StubTransport([
        .response(200, Data("[]".utf8)), .failure(.serverCertificateUntrusted),
    ])
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake"), defaults: VolatileDefaults(),
        store: UsageStore(url: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: transport) })
    model.start()
    await waitForState { model.connection == .failed("TLS error") }
    model.stop()
}

@Test @MainActor func demoUsesAttributedThirtyDayHistory() {
    let demo = IslandModel.demo()
    #expect(demo.usageReports.count == 3)
    #expect(demo.usageReports[.month]?.totals.requests == 30)
    #expect(demo.usageReports[.month]?.byModel.count == 4)
    #expect(
        demo.usageReports[.month]?.byAccount.contains { $0.id == "fake-config-api-key" } == true)
    #expect(demo.usageReports[.month]?.isPartial == true)
    #expect(demo.usageReports[.week]?.isPartial == false)
    #expect(demo.usageReports[.today]?.isPartial == false)
    #expect((demo.usageReports[.today]?.totals.requests ?? 0) > 0)
}

private final class RedirectRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    func reset() { lock.withLock { urls = [] } }
    var captured: [URL] { lock.withLock { urls } }
}

private final class RedirectProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RedirectRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.append(url)
        if url.host == "redirected.example" {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"files\":[]}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://redirected.example/credential-leak")!
        let response = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString])!
        client?.urlProtocol(
            self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func realURLSessionRefusesCrossHostRedirect() async {
    RedirectProtocol.requests.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RedirectProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ManagementClient(
        baseURL: URL(string: "https://origin.example")!, key: "fake-key", session: session)
    do {
        _ = try await client.authFiles()
        Issue.record("Expected HTTP 302 without redirect")
    } catch {
        #expect(error as? ManagementError == .http(302))
    }
    #expect(RedirectProtocol.requests.captured.map(\.host) == ["origin.example"])
}
