import Foundation
import Testing
@testable import IslandCore

private let filterNow = Fixtures.referenceNow
private func filterRecord(_ index: String?, model: String, provider: String, total: Int) -> UsageRecord {
    var record = UsageRecord(timestamp: filterNow, model: model, failed: index == "b",
                             tokens: UsageTokens(inputTokens: total / 2, outputTokens: total / 2, totalTokens: total))
    record.authIndex = index
    record.provider = provider
    return record
}
private func filterStore() -> UsageStore {
    UsageStore(url: nil, now: { filterNow }, initialRecords: [
        filterRecord("a", model: "shared", provider: "claude", total: 10),
        filterRecord("b", model: "shared", provider: "codex", total: 20),
        filterRecord(nil, model: "legacy", provider: "claude", total: 30),
        filterRecord("", model: "legacy", provider: "codex", total: 40),
    ])
}

@Test(arguments: UsageRange.allCases) func accountFilterPartitionsReportsAndSeries(_ range: UsageRange) async {
    let store = filterStore()
    let all = await store.report(range, accounts: [], now: filterNow)
    var tokens = 0
    var requests = 0
    var failed = 0
    var input = 0
    var output = 0
    for filter in [UsageAccountFilter.account("a"), .account("b"), .unattributed] {
        let report = await store.report(range, accounts: [], now: filterNow, filter: filter)
        let series = await store.series(range, now: filterNow, filter: filter)
        let combined = await store.seriesAll(now: filterNow, filter: filter)
        #expect(report.filter == filter)
        #expect(report.byAccount.count == 1)
        #expect(report.byModel.count == 1)
        #expect(series == combined[range])
        #expect(series.points.reduce(0) { $0 + $1.totalTokens } == report.totals.totalTokens)
        let providers = Set(series.points.flatMap(\.byProvider).map(\.provider))
        #expect(providers == [filter == .unattributed ? .other("") : filter == .account("a") ? .claude : .codex])
        tokens += report.totals.totalTokens
        requests += report.totals.requests
        failed += report.totals.failed
        input += report.totals.inputTokens
        output += report.totals.outputTokens
    }
    let allSeries = await store.series(range, now: filterNow)
    #expect(Set(allSeries.points.flatMap(\.byProvider).map(\.provider)) == [.claude, .codex, .other("")])
    #expect(all.filter == .all)
    #expect(all.totals.totalTokens == tokens)
    #expect(all.totals == UsageTotals(requests: requests, failed: failed, inputTokens: input, outputTokens: output, totalTokens: tokens))
    #expect(all.totals.totalTokens == 100)
    let empty = await store.report(range, accounts: [], now: filterNow, filter: .account("a' OR 1=1 --"))
    #expect(empty.filter == .account("a' OR 1=1 --"))
    #expect(empty.totals == .zero)
    #expect(empty.byAccount.isEmpty && empty.byModel.isEmpty)
    let emptySeries = await store.series(range, now: filterNow, filter: empty.filter)
    #expect(emptySeries.points.allSatisfy { $0.byProvider.isEmpty })
    #expect(UsageAccountFilter(authIndex: nil) == .unattributed)
    #expect(UsageAccountFilter(authIndex: "") == .unattributed)
    let options = await store.accountUsage(.halfYear, accounts: [], now: filterNow)
    #expect(options.count == 3)
    #expect(options.first { $0.authIndex == nil }?.provider.isUnknown == true)
    #expect(options.first { $0.authIndex == "a" }?.label == "Claude account · a")
}

@MainActor @Test func modelFiltersWithoutPollingAndPreservesOptions() async throws {
    let store = filterStore()
    let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: VolatileDefaults(), store: store, now: { filterNow })
    let connection = model.connection
    await model.applyUsageFilter(.account("a"))
    #expect(model.usageFilter == .account("a"))
    #expect(model.usageReports.values.allSatisfy { $0.filter == .account("a") && $0.totals.totalTokens == 10 })
    #expect(model.usageAccounts.count == 3)
    #expect(model.connection == connection && model.lastUpdated == nil)
    await store.reset()
    await model.applyUsageFilter(.account("a"))
    #expect(model.usageAccounts.first?.authIndex == "a")
    #expect(model.usageReports[.today]?.totals == .zero)
    await model.applyUsageFilter(.all)
    #expect(model.usageReports.values.allSatisfy { $0.filter == .all })
    try model.clearKey()
    #expect(model.usageFilter == .all && model.usageAccounts.isEmpty && model.usageReports.isEmpty)
}

@MainActor @Test func supersededFilterAndClearCannotPublishStaleReports() async throws {
    let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: VolatileDefaults(), store: filterStore(), now: { filterNow })
    let first = Task { await model.applyUsageFilter(.account("a")) }
    while model.usageFilter != .account("a") { await Task.yield() }
    await model.applyUsageFilter(.account("b"))
    await first.value
    #expect(model.usageFilter == .account("b"))
    #expect(model.usageReports.values.allSatisfy { $0.filter == .account("b") && $0.totals.totalTokens == 20 })
    let pending = Task { await model.applyUsageFilter(.unattributed) }
    while model.usageFilter != .unattributed { await Task.yield() }
    try model.clearKey()
    await pending.value
    #expect(model.usageReports.isEmpty && model.usageAccounts.isEmpty && model.usageFilter == .all)
}

@MainActor @Test func demoSupportsLocalAccountFiltering() async {
    let model = IslandModel.demo()
    guard let index = model.usageAccounts.compactMap(\.authIndex).first else {
        Issue.record("Demo has no attributed account")
        return
    }
    await model.applyUsageFilter(.account(index))
    #expect(model.usageReports.values.allSatisfy { $0.filter == .account(index) })
    #expect(model.usageAccounts.count > 1)
    await model.applyUsageFilter(.all)
    #expect(model.usageReports.values.allSatisfy { $0.filter == .all })
}

@Test func reopenedHistoryFiltersExistingUnattributedRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.sqlite")
    let original = UsageStore(url: url, now: { filterNow })
    await original.ingest([
        filterRecord(nil, model: "old", provider: "claude", total: 30),
        filterRecord("", model: "old", provider: "codex", total: 40),
        filterRecord("fake-claude-1", model: "known", provider: "claude", total: 10),
    ])
    let reopened = UsageStore(url: url, now: { filterNow })
    let files = try JSONDecoder().decode(AuthFilesResponse.self, from: Fixtures.data("auth-files"))
    let accounts = AccountMapper.accounts(from: files, live: [:], now: filterNow)
    let report = await reopened.report(.today, accounts: accounts, now: filterNow, filter: .unattributed)
    #expect(report.totals.totalTokens == 70 && report.totals.requests == 2)
    #expect(report.byAccount.first?.label == "Unattributed")
    let options = await reopened.accountUsage(.halfYear, accounts: accounts, now: filterNow)
    #expect(options.first { $0.authIndex == "fake-claude-1" }?.label == accounts.first { $0.authIndex == "fake-claude-1" }?.label)
    #expect(reopened.initialReports.values.allSatisfy { $0.filter == .all })
}

@MainActor @Test func synchronousFilterChoiceSurvivesImmediateStop() async throws {
    let model = IslandModel(keyStore: InMemoryKeyStore(), defaults: VolatileDefaults(), store: filterStore(), now: { filterNow })
    model.setUsageFilter(.account("a"))
    #expect(model.usageFilter == .account("a"))
    model.stop()
    await Task.yield()
    #expect(model.usageFilter == .account("a"))
    // A stopped recomputation can be retried with the committed choice.
    await model.applyUsageFilter(model.usageFilter)
    #expect(model.usageReports.values.allSatisfy { $0.filter == .account("a") })
    model.setUsageFilter(.account("b"))
    try model.clearKey()
    await Task.yield()
    #expect(model.usageFilter == .all && model.usageReports.isEmpty && model.usageAccounts.isEmpty)
}
