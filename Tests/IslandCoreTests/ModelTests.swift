import Foundation
import Testing
@testable import IslandCore

final class VolatileDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
}
@MainActor private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
    Issue.record("State transition timed out")
}
@MainActor @Test func modelNeedsKeyAndKeyLifecycle() async throws {
    let stub = StubTransport([.response(200, Data("[]".utf8)), .response(200, Fixtures.data("auth-files"))])
    let store = InMemoryKeyStore()
    let defaults = VolatileDefaults(); defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(keyStore: store, defaults: defaults, aggregator: UsageAggregator(persistenceURL: nil), clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    #expect(!model.hasKey); #expect(model.connection == .needsKey)
    model.start(); await Task.yield()
    #expect(await stub.captured().isEmpty)
    try model.saveKey(" fake-model-key ")
    await waitUntil { model.lastUpdated != nil }
    #expect(model.hasKey); #expect(model.accounts.count == 5)
    #expect(model.requestsLastHour == 456)
    #expect(model.featuredAccount?.id == "fake-alice")
    #expect(defaults.object(forKey: "management-key") == nil)
    try model.clearKey()
    #expect(!model.hasKey); #expect(model.connection == .needsKey); #expect(model.accounts.isEmpty)
    #expect(try store.read() == nil)
    model.stop()
}
@MainActor @Test func modelUsage404AndLastGoodState() async {
    let stub = StubTransport([.response(404, Data()), .response(200, Fixtures.data("auth-files")), .response(401, Data())])
    let defaults = VolatileDefaults(); defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(keyStore: InMemoryKeyStore(key: "test"), defaults: defaults, aggregator: UsageAggregator(persistenceURL: nil), clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    model.start(); await waitUntil { model.lastUpdated != nil }
    #expect(!model.usageAvailable)
    let old = model.accounts; let date = model.lastUpdated
    model.refreshNow(); await waitUntil { model.connection == .keyRejected }
    #expect(model.accounts == old); #expect(model.lastUpdated == date); #expect(model.hasKey)
    model.stop()
}
@MainActor @Test func modelURLPreferencesAndErrors() async {
    let stub = StubTransport([.failure(.cannotConnectToHost)])
    let defaults = VolatileDefaults(); defaults.set(false, forKey: "liveQuotaEnabled")
    let model = IslandModel(keyStore: InMemoryKeyStore(key: "test"), defaults: defaults, aggregator: UsageAggregator(persistenceURL: nil), clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) })
    #expect(!model.applyBaseURL("http://example.com"))
    #expect(model.applyBaseURL(" http://localhost:8317/ "))
    await waitUntil { if case .proxyDown = model.connection { return true }; return false }
    #expect(defaults.string(forKey: "baseURL") == "http://localhost:8317")
    model.liveQuotaEnabled = true; #expect(defaults.bool(forKey: "liveQuotaEnabled"))
    model.stop()
}
@MainActor @Test func demoIsImmediateAndFutureDated() {
    let model = IslandModel.demo()
    #expect(model.accounts.count == 5); #expect(model.usage.today.count == 3)
    #expect(model.accounts.first?.bindingWindow?.resetsAt ?? .distantPast > Date())
    #expect(model.requestsLastHour == 6)
    if case .connected = model.connection {} else { Issue.record("Demo should be connected") }
    let accounts = model.accounts
    model.start(); model.refreshNow(); model.stop()
    #expect(model.accounts == accounts)
}
