import IslandCore
import SwiftUI

/// Local session responses, intentionally separate from the proxy's request counters.
struct ProjectsPage: View {
    let projects: ProjectUsageMonitor
    @Binding var range: UsageRange
    @Binding var source: ProjectUsageSource?

    var body: some View {
        VStack(spacing: DashboardMetrics.spacing) {
            SectionHeader(title: "Local usage") {
                HStack(spacing: 6) {
                    sourceChoices
                    RangePicker(range: $range)
                }
            }
            if !projects.isDemo, !projects.progress.ready {
                CardChrome {
                    VStack(alignment: .leading, spacing: 4) {
                        note(projects.progress.stale ? "Local index needs attention." : "Indexing retained local logs…", symbol: "hourglass")
                        detail("Totals shown so far can change as responses and project context are indexed.")
                        let found = projects.progress.sources.reduce(0) { $0 + $1.discoveredFiles }
                        if found > 0 { detail("\(found) log files discovered in this pass.") }
                    }
                }
            }
            if let warning = projects.warning {
                CardChrome {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CardChrome {
                VStack(alignment: .leading, spacing: 5) {
                    switch projects.log {
                    case .loading:
                        note("Reading local session usage…", symbol: "hourglass")
                    case .missing:
                        note("No local session logs found.", symbol: "doc.text.magnifyingglass")
                        detail("Reads Claude Code projects and Codex sessions on this Mac.")
                    case .unreadable(let reason):
                        note("Can't read local session usage: " + reason, symbol: "exclamationmark.triangle.fill")
                    case .loaded:
                        if let report = projects.report(for: range, source: source), report.totals.responses > 0 {
                            totals(report.totals)
                        } else {
                            note(projects.progress.ready || projects.isDemo
                                 ? "No recorded responses from \(source?.title ?? "local sessions") in this range."
                                 : "No matching responses indexed yet.", symbol: "tray")
                            if let last = projects.lastResponse {
                                detail("Last local response \(last.formatted(.dateTime.month(.abbreviated).day().hour().minute())).")
                            }
                        }
                    }
                    if projects.hasCachedUsage, projects.log != .loaded,
                       let report = projects.report(for: range, source: source) {
                        totals(report.totals)
                        detail("Last indexed totals · may be stale while the source or index is unavailable.")
                    }
                    detail(projects.isDemo ? "Demo fixtures · not your local usage." : "Local session usage · \(source?.title ?? "Claude Code + Codex")")
                    detail("Retained logs only; separate from AI usage and Jev. Responses are not proxy requests.")
                }
            }
            if let report = projects.report(for: range, source: source), !report.projects.isEmpty {
                if projects.projectPageIsStale(for: range, source: source) {
                    HStack(spacing: 8) {
                        detail("Project rows are from the previous index snapshot.")
                        Button("Refresh list") { projects.refreshProjectList(for: range, source: source) }
                            .font(.system(size: 9.5))
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                }
                BreakdownCard(title: "By project", symbol: "folder", rows: report.projects.map { row in
                    let t = row.totals
                    return BreakdownRow(id: row.id, name: row.name, provider: nil,
                                        totals: UsageTotals(requests: t.responses, inputTokens: t.inputTokens,
                                                            outputTokens: t.outputTokens, totalTokens: t.totalTokens),
                                        detail: row.path)
                }, countLabel: "resp", countName: "responses")
                if report.projectCount > 20 {
                    HStack(spacing: 8) {
                        Button("Previous") {
                            let clickedRange = range, clickedSource = source
                            Task { await projects.loadProjectPage(for: clickedRange, source: clickedSource, direction: .previous) }
                        }
                        .disabled(!report.hasPrevious || projects.isLoadingProjectPage || projects.projectPageIsStale(for: range, source: source))
                        Spacer(minLength: 4)
                        Text("Page \(projects.projectPageNumber(for: range, source: source)) · \(report.projectCount) projects")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: 4)
                        Button("Next") {
                            let clickedRange = range, clickedSource = source
                            Task { await projects.loadProjectPage(for: clickedRange, source: clickedSource, direction: .next) }
                        }
                        .disabled(!report.hasNext || projects.isLoadingProjectPage || projects.projectPageIsStale(for: range, source: source))
                    }
                    .font(.system(size: 9.5))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .onAppear { projects.selectProjectReport(for: range, source: source) }
        .onChange(of: range) { _, selected in projects.selectProjectReport(for: selected, source: source) }
        .onChange(of: source) { _, selected in projects.selectProjectReport(for: range, source: selected) }
    }

    /// Inline choices keep all clicks inside the island's hit area (no separate menu window).
    private var sourceChoices: some View {
        HStack(spacing: 1) {
            ForEach([ProjectUsageSource?.none] + ProjectUsageSource.allCases.map(Optional.some), id: \.self) { choice in
                Button {
                    withAnimation(Theme.emphasis) { source = choice }
                } label: {
                    Text(choice == .claudeCode ? "Claude" : (choice?.title ?? "All"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(choice == source ? .black : Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(choice == source ? Color.white : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Filter local usage: " + (choice?.title ?? "All sources"))
                .accessibilityLabel("Local usage: " + (choice?.title ?? "All sources"))
                .accessibilityAddTraits(choice == source ? .isSelected : [])
            }
        }
        .padding(1.5)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func totals(_ totals: ProjectUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.tokens(totals.totalTokens))
                    .font(Theme.number(18, .medium))
                    .contentTransition(.numericText())
                Text("tokens · \(totals.responses) responses")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
            }
            detail("in \(Format.tokens(totals.inputTokens)) · out \(Format.tokens(totals.outputTokens))")
            detail("Cache read \(Format.tokens(totals.cacheReadTokens)) · write \(Format.tokens(totals.cacheWriteTokens)) (included in input)")
        }
        .accessibilityElement(children: .combine)
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
            .fixedSize(horizontal: false, vertical: true)
    }
}
