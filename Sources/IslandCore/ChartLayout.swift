import Foundation

public struct ChartLegend: Equatable, Sendable {
    public var shown: [Provider]
    public var overflow: Int

    public init(shown: [Provider], overflow: Int) {
        self.shown = shown
        self.overflow = overflow
    }
}

/// Pure layout and hit-testing helpers; time-sensitive decisions use the supplied clock.
public enum ChartLayout {
    public static func legend(_ series: UsageSeries, now: Date, limit: Int = 3) -> ChartLegend {
        var totals: [Provider: Int] = [:]
        for point in series.points where point.recorded && !isFuture(point, now: now) {
            for tokens in point.byProvider where tokens.totalTokens != 0 {
                totals[tokens.provider] = addingCounts(totals[tokens.provider] ?? 0, tokens.totalTokens)
            }
        }
        let providers = totals.keys.sorted {
            if totals[$0] != totals[$1] { return totals[$0, default: 0] > totals[$1, default: 0] }
            return $0.displayName < $1.displayName
        }
        let shown = Array(providers.prefix(max(0, limit)))
        return ChartLegend(shown: shown, overflow: providers.count - shown.count)
    }

    public static func axisTicks(_ series: UsageSeries, calendar: Calendar) -> [Date] {
        switch series.range {
        case .today:
            return series.points.compactMap {
                [0, 6, 12, 18].contains(calendar.component(.hour, from: $0.start)) ? $0.start : nil
            }
        case .week:
            return []
        case .month:
            guard let first = series.points.first, let last = series.points.last else { return [] }
            return [first.start, series.points[series.points.count / 2].start, last.start]
        }
    }

    public static func point(at date: Date, in series: UsageSeries, now: Date) -> UsageSeriesPoint? {
        series.points.first { date >= $0.start && date < $0.end && !isFuture($0, now: now) }
    }

    public static func unrecordedEnd(_ series: UsageSeries) -> Date? {
        guard series.points.contains(where: { !$0.recorded }) else { return nil }
        return series.points.first(where: { $0.recorded || $0.partial })?.start
            ?? series.points.last?.end
    }

    public static func isFuture(_ point: UsageSeriesPoint, now: Date) -> Bool {
        point.start > now
    }
}
