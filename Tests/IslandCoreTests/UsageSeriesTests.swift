import Foundation
import Testing

@testable import IslandCore

private func seriesCalendar(_ zone: String = "UTC") -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  return calendar
}

private func seriesDate(_ raw: String) -> Date { APIDateParser.parse(raw)! }
private let seriesNow = seriesDate("2026-10-02T12:00:00Z")

private func seriesRecord(
  at date: Date, provider: String = "claude", model: String = "model",
  total: Int = 30
) -> UsageRecord {
  var record = UsageRecord(
    timestamp: date, model: model,
    tokens: UsageTokens(inputTokens: 10, outputTokens: 20, totalTokens: total))
  record.authIndex = provider
  record.provider = provider
  return record
}

@Test func hourlySeriesZeroFillsGapsAndPlacesBoundaryInNextPoint() async {
  let midnight = seriesCalendar().startOfDay(for: seriesNow)
  let store = UsageStore(url: nil, calendar: seriesCalendar(), now: { seriesNow })
  await store.ingest([
    seriesRecord(at: midnight),
    seriesRecord(at: midnight.addingTimeInterval(3600), total: 50),
    seriesRecord(at: midnight.addingTimeInterval(-1), total: 100),
  ])
  let series = await store.series(.today, now: seriesNow)
  #expect(series.granularity == .hour)
  #expect(series.points.count == 24)
  #expect(series.points[0].id == midnight)
  #expect(series.points[0].totalTokens == 30)
  #expect(series.points[1].totalTokens == 50)
  #expect(series.points.dropFirst(2).allSatisfy { $0.byProvider.isEmpty && $0.totalTokens == 0 })
  #expect(series.points.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
  #expect(series.peakTokens == 50)
  #expect(series.points.last?.end == midnight.addingTimeInterval(86400))
}

@Test(arguments: [UsageRange.week, .month])
func dailySeriesCountsAndCalendarBoundaries(_ range: UsageRange) async {
  let calendar = seriesCalendar("America/New_York")
  let now = seriesDate("2026-11-03T12:00:00Z")
  let start = range.start(now: now, calendar: calendar)
  let store = UsageStore(url: nil, calendar: calendar, now: { now })
  await store.ingest([seriesRecord(at: start), seriesRecord(at: start.addingTimeInterval(-1))])
  let series = await store.series(range, now: now)
  #expect(series.granularity == .day)
  #expect(series.points.count == (range == .week ? 7 : 30))
  #expect(series.points.first?.start == start)
  #expect(series.points.first?.totalTokens == 30)
  #expect(
    series.points.last?.end
      == calendar.date(
        byAdding: .day, value: 1,
        to: calendar.startOfDay(for: now)))
  for (index, point) in series.points.enumerated() {
    #expect(point.start == calendar.date(byAdding: .day, value: index, to: start))
    #expect(point.end == calendar.date(byAdding: .day, value: 1, to: point.start))
    if index > 0 { #expect(series.points[index - 1].end == point.start) }
  }
  #expect(series.points.contains { $0.end.timeIntervalSince($0.start) == 25 * 3600 })
}

@Test(arguments: [("2026-03-08T16:00:00Z", 23), ("2026-11-01T17:00:00Z", 25)])
func hourlySeriesRespectsDST(_ timestamp: String, _ count: Int) async {
  let now = seriesDate(timestamp)
  let calendar = seriesCalendar("America/New_York")
  let store = UsageStore(url: nil, calendar: calendar, now: { now })
  let series = await store.series(.today, now: now)
  #expect(series.points.count == count)
  #expect(Set(series.points.map(\.id)).count == count)
  #expect(series.points.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
  #expect(series.points.first?.start == calendar.startOfDay(for: now))
  #expect(
    series.points.last?.end
      == calendar.date(
        byAdding: .day, value: 1,
        to: calendar.startOfDay(for: now)))
}

@Test(arguments: ["Asia/Kolkata", "Asia/Kathmandu"])
func offsetSeriesPlacesLocalMidnightInFirstPoint(_ zone: String) async {
  let calendar = seriesCalendar(zone)
  let midnight = calendar.startOfDay(for: seriesNow)
  let store = UsageStore(url: nil, calendar: calendar, now: { seriesNow })
  await store.ingest([
    seriesRecord(at: midnight),
    seriesRecord(at: midnight.addingTimeInterval(-60), total: 100),
  ])
  let series = await store.series(.today, now: seriesNow)
  #expect(series.points.count == 24)
  #expect(series.points.first?.start == midnight)
  #expect(series.points.first?.totalTokens == 30)
  #expect(series.points.dropFirst().allSatisfy { $0.totalTokens == 0 })
}

@Test func seriesStacksCanonicalProvidersAndSortsTotalsThenNames() async {
  let stacked = UsageStore(url: nil, calendar: seriesCalendar(), now: { seriesNow })
  await stacked.ingest([
    seriesRecord(at: seriesNow.addingTimeInterval(-3600), total: 10),
    seriesRecord(at: seriesNow.addingTimeInterval(-2700), provider: "anthropic", total: 20),
    seriesRecord(at: seriesNow.addingTimeInterval(-3600), provider: "codex", total: 30),
    seriesRecord(at: seriesNow.addingTimeInterval(-3600), provider: "gemini", total: 50),
    seriesRecord(at: seriesNow.addingTimeInterval(-3600), provider: "", total: 5),
  ])
  let point = await stacked.series(.today, now: seriesNow).points[11]
  #expect(point.byProvider.map(\.provider) == [.gemini, .claude, .codex, .other("")])
  #expect(
    point.byProvider[1]
      == ProviderTokens(
        provider: .claude, inputTokens: 20,
        outputTokens: 40, totalTokens: 30, requests: 2))
  #expect(point.totalTokens == 115)
  #expect(await stacked.series(.today, now: seriesNow).peakTokens == 115)
}

@Test func seriesFlagsRespectTrackingAndNowBoundaries() async {
  let midnight = seriesCalendar().startOfDay(for: seriesNow)
  let tracking = midnight.addingTimeInterval(90 * 60)
  let now = midnight.addingTimeInterval(2 * 3600)
  let store = UsageStore(
    url: nil, calendar: seriesCalendar(), now: { now }, trackingSince: tracking)
  let series = await store.series(.today, now: now)
  #expect(series.trackingSince == tracking)
  #expect(!series.points[0].recorded && !series.points[0].partial)
  #expect(series.points[1].recorded && series.points[1].partial)
  #expect(series.points[2].recorded && !series.points[2].partial && !series.points[2].future)
  #expect(series.points[3].future)
  let boundaryStore = UsageStore(
    url: nil, calendar: seriesCalendar(), now: { now },
    trackingSince: now)
  let boundary = await boundaryStore.series(.today, now: now)
  #expect(!boundary.points[1].recorded && !boundary.points[1].partial)
  #expect(boundary.points[2].recorded && boundary.points[2].partial)
  let empty = await UsageStore(url: nil, calendar: seriesCalendar()).series(.today, now: now)
  #expect(empty.points.allSatisfy { !$0.recorded && !$0.partial })
  #expect(empty.peakTokens == 0)
}

@MainActor @Test func modelPublishesSeriesAfterStubbedPoll() async {
  let stub = StubTransport([
    .response(200, Fixtures.data("usage-queue")), .response(200, Fixtures.data("auth-files")),
  ])
  let defaults = VolatileDefaults()
  defaults.set(false, forKey: "liveQuotaEnabled")
  let model = IslandModel(
    keyStore: InMemoryKeyStore(key: "fake"), defaults: defaults,
    store: UsageStore(url: nil, calendar: seriesCalendar(), now: { Fixtures.referenceNow }),
    clientFactory: { ManagementClient(baseURL: $0, key: $1, transport: stub) },
    now: { Fixtures.referenceNow })
  model.start()
  defer { model.stop() }
  for _ in 0..<1000 {
    if model.lastUpdated != nil { break }
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(model.lastUpdated != nil)
  #expect(model.usageSeries.count == 3)
  for range in UsageRange.allCases {
    #expect(
      model.usageSeries[range]?.points.reduce(0) { $0 + $1.totalTokens }
        == model.usageReports[range]?.totals.totalTokens)
  }
  try? model.clearKey()
  #expect(model.usageSeries.isEmpty)
}

@MainActor @Test func demoPopulatesNonemptyUsageSeries() {
  let model = IslandModel.demo()
  #expect(model.usageSeries.count == 3)
  #expect(model.usageSeries.values.allSatisfy { !$0.points.isEmpty && $0.peakTokens > 0 })
}
