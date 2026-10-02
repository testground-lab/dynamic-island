import Charts
import IslandCore
import SwiftUI

/// Token usage over the selected range: one bar per hour (Today) or per day
/// (7d / 30d), stacked by provider in provider colours. Periods before
/// tracking began are shaded as "not recorded" rather than drawn as zero.
/// Hovering a bar dims the others and puts its value in the caption.
struct TokenChart: View {
    var series: UsageSeries
    var now: Date = .now
    static let plotHeight: CGFloat = 58

    @State private var hovered: Date?

    private var unit: Calendar.Component { series.granularity == .hour ? .hour : .day }
    private var drawn: [UsageSeriesPoint] { series.points.filter { $0.recorded && !$0.future } }
    private var selectedPoint: UsageSeriesPoint? {
        guard let hovered else { return nil }
        return series.points.first { $0.start <= hovered && hovered < $0.end && !$0.future }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                legend
            }
            chart
                .frame(height: Self.plotHeight)
            if series.range == .week {
                // One letter under each day; Charts drops the last centred label.
                HStack(spacing: 0) {
                    ForEach(series.points) { point in
                        Text(axisLabel(point.start))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.granularity == .hour ? "Tokens per hour, today" : "Tokens per day, \(series.range.title)")
        .accessibilityValue(summary)
    }

    // MARK: Chart

    private var chart: some View {
        let points = series.points
        let domainStart = points.first?.start ?? now
        let domainEnd = points.last?.end ?? now
        let selected = selectedPoint?.start
        return Chart {
            if let boundary = unrecordedEnd, boundary > domainStart {
                RectangleMark(xStart: .value("From", domainStart), xEnd: .value("To", min(boundary, domainEnd)))
                    .foregroundStyle(.white.opacity(0.05))
                    .annotation(position: .overlay, alignment: .center) {
                        if boundary.timeIntervalSince(domainStart) > (domainEnd.timeIntervalSince(domainStart)) * 0.2 {
                            Text("not recorded")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
            }
            ForEach(drawn) { point in
                ForEach(point.byProvider, id: \.provider) { part in
                    BarMark(x: .value("Time", point.start, unit: unit),
                            y: .value("Tokens", part.totalTokens))
                        .foregroundStyle(part.provider.tint.opacity(selected == nil || selected == point.start ? 0.95 : 0.4))
                        .cornerRadius(2)
                }
            }
            if let first = drawn.first, let last = drawn.last {
                // A faint baseline under the recorded span, so idle periods read as zero.
                RuleMark(xStart: .value("From", first.start), xEnd: .value("To", last.end), y: .value("Zero", 0))
                    .foregroundStyle(.white.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: 0...max(series.peakTokens, 1))
        .chartYAxis(.hidden)
        .chartXAxis(series.range == .week ? .hidden : .automatic)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
        .chartXSelection(value: $hovered)
        .chartLegend(.hidden)
    }

    /// End of the span before tracking began (nil when everything is recorded).
    private var unrecordedEnd: Date? {
        guard series.points.contains(where: { !$0.recorded }) else { return nil }
        return series.trackingSince ?? series.points.last?.end
    }

    private var legend: some View {
        let providers = providersInRange
        return HStack(spacing: 6) {
            ForEach(providers.prefix(3), id: \.self) { provider in
                HStack(spacing: 3) {
                    Circle().fill(provider.tint).frame(width: 5, height: 5)
                    Text(provider.isUnknown ? "Other" : provider.displayName)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var providersInRange: [Provider] {
        var totals: [Provider: Int] = [:]
        for point in drawn { for part in point.byProvider { totals[part.provider, default: 0] += part.totalTokens } }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: Text

    private var caption: String {
        if let point = selectedPoint {
            guard point.recorded else { return "\(longLabel(point.start)) · not recorded" }
            return "\(longLabel(point.start)) · \(Format.tokens(point.totalTokens)) tokens"
        }
        return series.granularity == .hour ? "Tokens per hour" : "Tokens per day"
    }

    private var axisDates: [Date] {
        let points = series.points
        guard !points.isEmpty else { return [] }
        switch series.range {
        case .today:
            return points.enumerated().filter { $0.offset % 6 == 0 }.map(\.element.start)
        case .week:
            return []
        case .month:
            return points.enumerated().filter { $0.offset % 7 == 0 }.map(\.element.start)
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch series.range {
        case .today: date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))
        case .week: date.formatted(.dateTime.weekday(.narrow))
        case .month: date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private func longLabel(_ date: Date) -> String {
        series.granularity == .hour
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// VoiceOver: peak, total and how many periods had usage.
    private var summary: String {
        let recorded = drawn
        guard let peak = recorded.max(by: { $0.totalTokens < $1.totalTokens }), peak.totalTokens > 0 else {
            return recorded.isEmpty ? "Nothing recorded in this range yet." : "No tokens used in this range."
        }
        let total = recorded.reduce(0) { $0 + $1.totalTokens }
        let active = recorded.filter { $0.totalTokens > 0 }.count
        let noun = series.granularity == .hour ? "hours" : "days"
        return "Peak \(Format.tokens(peak.totalTokens)) tokens at \(longLabel(peak.start)). "
            + "\(Format.tokens(total)) tokens in total; \(active) of \(recorded.count) recorded \(noun) had usage."
    }
}
