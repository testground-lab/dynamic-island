import IslandCore
import SwiftUI

extension DashboardPage {
    var title: String {
        switch self {
        case .usage: "AI usage"
        case .jev: "Jev"
        }
    }
}

/// Page two: calls the jev-model-router hook logged, per range, with tokens,
/// an estimated spend and the same token chart as the Usage section. Always
/// explains itself when there is nothing to show.
struct JevPage: View {
    let jev: JevUsageMonitor
    @Binding var range: UsageRange

    var body: some View {
        let state = jev.state(for: range)
        VStack(spacing: DashboardMetrics.spacing) {
            SectionHeader(title: "Usage") { RangePicker(range: $range) }
            CardChrome {
                VStack(alignment: .leading, spacing: 5) {
                    switch state {
                    case .data(let report):
                        totals(report.totals)
                        TokenChart(series: report.series).padding(.top, 2)
                        if report.totals.failed > 0 { failures(report.totals) }
                    case .empty(let lastCall):
                        note("No Jev calls in this range.", symbol: "tray")
                        if let lastCall {
                            detail("Last call \(lastCall.formatted(.dateTime.month(.abbreviated).day().hour().minute())).")
                        }
                    case .missing:
                        note("Jev usage appears once the jev-model-router hook logs a call.", symbol: "doc.text.magnifyingglass")
                        detail("Reads ~/.claude/jev-model-router/usage.jsonl")
                    case .unreadable(let reason):
                        Label("Can't read the Jev log: \(reason)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        detail("~/.claude/jev-model-router/usage.jsonl")
                    case .loading:
                        note("Reading the Jev log…", symbol: "hourglass")
                    }
                }
            }
        }
    }

    private func totals(_ t: JevTotals) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.tokens(t.totalTokens)).font(Theme.number(18, .medium)).contentTransition(.numericText())
                    Text("tokens · \(t.requests) req").font(.system(size: 9.5)).foregroundStyle(Theme.secondary)
                    if t.failed > 0 {
                        Text("· \(t.failed) failed").font(.system(size: 9.5)).foregroundStyle(Theme.warning)
                    }
                }
                Text("in \(Format.tokens(t.inputTokens)) · out \(Format.tokens(t.outputTokens))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(JevPricing.formatted(usd: t.estimatedSpendUSD))
                    .font(Theme.number(14, .medium))
                    .contentTransition(.numericText())
                Text("est. spend").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
            }
            .help("Estimate: input tokens × $\(JevPricing.inputUSDPerMillionTokens) per million. Output tokens are free at the moment.")
            .accessibilityElement(children: .combine)
        }
    }

    /// "1 timeout · 1 HTTP 502", most frequent first.
    private func failures(_ t: JevTotals) -> some View {
        let parts = t.failuresByError
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) \(Self.errorName($0.key))" }
        return Label(parts.joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.warning)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel("Failed calls: " + parts.joined(separator: ", "))
    }

    static func errorName(_ raw: String) -> String {
        if raw.hasPrefix("http_") { return "HTTP " + raw.dropFirst(5) }
        return raw
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
