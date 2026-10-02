import Charts
import IslandCore
import SwiftUI

/// Bars of token use across the chosen range (hours for Today, days for
/// 7d/30d), each split by provider. Before recording began the plot is
/// shaded instead of showing zeros. Pointing at a bar outlines its period and
/// reads it out above the plot.
struct TokenChart: View {
    var series: UsageSeries
    static let plotHeight: CGFloat = 58

    @State private var pointer: Date?

    private var unit: Calendar.Component { series.granularity == .hour ? .hour : .day }

    var body: some View {
        let now = Date()
        let focus = pointer.flatMap { ChartLayout.point(at: $0, in: series, now: now) }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                readout(focus)
                Spacer(minLength: 4)
                LegendRow(legend: ChartLayout.legend(series, now: now))
            }
            plot(now: now, focus: focus)
                .frame(height: Self.plotHeight)
            if series.range == .week { weekdayRow }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.granularity == .hour ? "Hourly tokens today" : "Daily tokens, \(series.range.title)")
        .accessibilityValue(spokenSummary(now: now))
    }

    // MARK: Plot

    private func plot(now: Date, focus: UsageSeriesPoint?) -> some View {
        let lower = series.points.first?.start ?? now
        let upper = series.points.last?.end ?? now
        let visible = series.points.filter { $0.recorded && !ChartLayout.isFuture($0, now: now) }
        return Chart {
            if let gapEnd = ChartLayout.unrecordedEnd(series), gapEnd > lower {
                RectangleMark(xStart: .value("Start", lower), xEnd: .value("End", min(gapEnd, upper)))
                    .foregroundStyle(.white.opacity(0.045))
                    .annotation(position: .overlay) {
                        // Only label the span when it's wide enough to hold the words.
                        if min(gapEnd, upper).timeIntervalSince(lower) >= upper.timeIntervalSince(lower) * 0.18 {
                            Text("not recorded")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize()
                        }
                    }
            }
            if let focus {
                RectangleMark(xStart: .value("Start", focus.start), xEnd: .value("End", focus.end))
                    .foregroundStyle(.white.opacity(0.09))
            }
            ForEach(visible) { point in
                ForEach(point.byProvider, id: \.provider) { slice in
                    BarMark(x: .value("Period", point.start, unit: unit),
                            y: .value("Tokens", slice.totalTokens))
                        .foregroundStyle(slice.provider.tint.opacity(point.partial ? 0.5 : 0.9))
                        .cornerRadius(1.5)
                }
            }
            if let first = visible.first, let last = visible.last {
                RuleMark(xStart: .value("Start", first.start), xEnd: .value("End", last.end), y: .value("Zero", 0))
                    .foregroundStyle(.white.opacity(0.14))
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
            }
        }
        .chartXScale(domain: lower...upper)
        .chartYScale(domain: 0...max(series.peakTokens, 1))
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis(series.range == .week ? .hidden : .automatic)
        .chartXAxis {
            let ticks = ChartLayout.axisTicks(series, calendar: .autoupdatingCurrent)
            AxisMarks(values: ticks) { value in
                // The last tick sits near the right edge: hang its label leftwards.
                AxisValueLabel(anchor: value.as(Date.self) == ticks.last && series.range == .month ? .topTrailing : nil) {
                    if let date = value.as(Date.self) {
                        Text(tickLabel(date)).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointer = proxy.value(atX: location.x, as: Date.self)
                    case .ended: pointer = nil
                    }
                }
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(series.points) { point in
                Text(point.start.formatted(.dateTime.weekday(.abbreviated)).prefix(2))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Text

    @ViewBuilder private func readout(_ focus: UsageSeriesPoint?) -> some View {
        Group {
            if let focus {
                Text(periodName(focus) + "  ")
                    + Text(focus.recorded ? Format.tokens(focus.totalTokens) : "not recorded")
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text(series.granularity == .hour ? "Hourly tokens" : "Daily tokens")
            }
        }
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }

    private func periodName(_ point: UsageSeriesPoint) -> String {
        series.granularity == .hour
            ? "\(clock(point.start))–\(clock(point.end))"
            : point.start.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// 24-hour clock regardless of locale, so "06" and "18" can't be confused.
    private func clock(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent))
    }

    private func tickLabel(_ date: Date) -> String {
        switch series.range {
        case .today: String(clock(date).prefix(2))
        case .week, .month: date.formatted(.dateTime.month(.defaultDigits).day())
        }
    }

    private func spokenSummary(now: Date) -> String {
        let recorded = series.points.filter { $0.recorded && !ChartLayout.isFuture($0, now: now) }
        guard let top = recorded.max(by: { $0.totalTokens < $1.totalTokens }), top.totalTokens > 0 else {
            return recorded.isEmpty ? "Nothing recorded in this range yet." : "No tokens used in this range."
        }
        let busy = recorded.filter { $0.totalTokens > 0 }.count
        let legend = ChartLayout.legend(series, now: now, limit: .max)
        let unitName = series.granularity == .hour ? "hours" : "days"
        return "Busiest \(periodName(top)) with \(Format.tokens(top.totalTokens)) tokens. "
            + "\(busy) of \(recorded.count) recorded \(unitName) used tokens, across \(legend.shown.count) providers."
    }
}

/// Provider dots for the chart; extra providers collapse into "+N".
private struct LegendRow: View {
    var legend: ChartLegend

    var body: some View {
        HStack(spacing: 6) {
            ForEach(legend.shown, id: \.self) { provider in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(provider.tint).frame(width: 6, height: 6)
                    Text(provider.isUnknown ? "Other" : provider.displayName)
                }
            }
            if legend.overflow > 0 { Text("+\(legend.overflow)") }
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(Theme.tertiary)
        .lineLimit(1)
    }
}
