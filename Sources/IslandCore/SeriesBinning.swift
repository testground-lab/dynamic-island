import Foundation

extension UsageSeries {
    public struct Entry: Hashable, Sendable {
        public var start: Date
        public var provider: Provider
        public var totals: UsageTotals

        public init(start: Date, provider: Provider, totals: UsageTotals) {
            self.start = start
            self.provider = provider
            self.totals = totals
        }
    }

    /// Bins entries into the range's calendar hours (Today) or days (7d/30d), DST-safe.
    public static func binned(
        _ range: UsageRange, entries: [Entry], now: Date, calendar: Calendar, trackingSince: Date?
    ) -> UsageSeries {
        let start = range.start(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today)
        else {
            return UsageSeries(range: range, granularity: range.granularity, points: [],
                               trackingSince: trackingSince)
        }
        var intervals: [(start: Date, end: Date)] = []
        var cursor = start
        while cursor < end {
            let boundary = range.granularity == .hour
                ? calendar.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0),
                                    matchingPolicy: .nextTime) ?? end
                : calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
            let next = min(boundary, end)
            guard next > cursor else { break }
            intervals.append((cursor, next))
            cursor = next
        }
        var bins = Array(repeating: [Provider: UsageTotals](), count: intervals.count)
        for row in entries {
            let bucket = row.start
            guard bucket >= start, bucket < end else { continue }
            // Upper bound on starts handles variable-length calendar hours and days.
            var lower = 0
            var upper = intervals.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if intervals[middle].start <= bucket { lower = middle + 1 }
                else { upper = middle }
            }
            let index = lower - 1
            guard bins.indices.contains(index), bucket < intervals[index].end else { continue }
            let provider = row.provider
            let totals = row.totals
            let previous = bins[index][provider] ?? .zero
            bins[index][provider] = UsageTotals(
                requests: addingCounts(previous.requests, totals.requests),
                inputTokens: addingCounts(previous.inputTokens, totals.inputTokens),
                outputTokens: addingCounts(previous.outputTokens, totals.outputTokens),
                totalTokens: addingCounts(previous.totalTokens, totals.totalTokens))
        }
        let points = intervals.enumerated().map { index, interval in
            UsageSeriesPoint(
                start: interval.start, end: interval.end,
                byProvider: bins[index].map { provider, totals in
                    ProviderTokens(provider: provider, inputTokens: totals.inputTokens,
                                   outputTokens: totals.outputTokens, totalTokens: totals.totalTokens,
                                   requests: totals.requests)
                }, trackingSince: trackingSince, now: now)
        }
        return UsageSeries(range: range, granularity: range.granularity, points: points,
                           trackingSince: trackingSince)
    }
}
