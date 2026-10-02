import Foundation
import Testing

@testable import IslandCore

private actor QuotaTransport: HTTPTransport {
    private var active = 0
    private var peak = 0
    private var calls = 0
    private var accountsPresent = true
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.lastPathComponent
        let body: Data
        if path == "auth-files" {
            let files = (0..<(accountsPresent ? 8 : 0)).map {
                #"{"id":"fake-\#($0)","auth_index":"fake-\#($0)","provider":"claude"}"#
            }.joined(separator: ",")
            body = Data(("{\"files\":[" + files + "]}").utf8)
        } else if path == "api-call" {
            active += 1
            calls += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            body = Fixtures.data("api-call-claude-usage")
        } else {
            body = Data("[]".utf8)
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    func statistics() -> (Int, Int) { (calls, peak) }
    func setAccountsPresent(_ present: Bool) { accountsPresent = present }
}
@MainActor @Test func livePollingHasThreeConcurrentCallsAndThrottlesRefresh() async {
    let transport = QuotaTransport()
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake-key"), defaults: VolatileDefaults(),
        aggregator: UsageAggregator(persistenceURL: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: transport) })
    model.start()
    for _ in 0..<1000 {
        if model.accounts.count == 8
            && model.accounts.allSatisfy({
                if case .live = $0.quotaSource { return true }
                return false
            })
        {
            break
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.accounts.count == 8)
    #expect(
        model.accounts.allSatisfy {
            if case .live = $0.quotaSource { return true }
            return false
        })
    let (calls, peak) = await transport.statistics()
    #expect(calls == 8)
    #expect(peak == 3)
    let previous = model.lastUpdated
    model.refreshNow()
    for _ in 0..<1000 {
        if model.lastUpdated != previous { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await transport.statistics().0 == 8)
    model.stop()
}

@MainActor @Test func removedAccountsDiscardLiveAttemptThrottle() async {
    let transport = QuotaTransport()
    let model = IslandModel(
        keyStore: InMemoryKeyStore(key: "fake-key"), defaults: VolatileDefaults(),
        aggregator: UsageAggregator(persistenceURL: nil),
        clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: transport) }
    )
    model.start()
    for _ in 0..<1000 {
        if model.accounts.count == 8
            && model.accounts.allSatisfy({
                if case .live = $0.quotaSource { return true }
                return false
            })
        {
            break
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await transport.statistics().0 == 8)
    await transport.setAccountsPresent(false)
    model.refreshNow()
    for _ in 0..<1000 {
        if model.accounts.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.accounts.isEmpty)
    await transport.setAccountsPresent(true)
    model.refreshNow()
    for _ in 0..<1000 {
        if model.accounts.count == 8
            && model.accounts.allSatisfy({
                if case .live = $0.quotaSource { return true }
                return false
            })
        {
            break
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await transport.statistics().0 == 16)
    model.stop()
}
