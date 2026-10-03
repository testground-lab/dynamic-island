import IslandCore
import SwiftUI

enum DashboardMetrics {
    /// Content column of the open island (480 wide minus shoulders and insets).
    static let contentWidth: CGFloat = 424
    static let spacing: CGFloat = 6
    static let cardRadius: CGFloat = 14
}

/// The open island's content: a header row beside the camera, then one of two
/// pages, switched by a sideways swipe or the header's dots. Page one scrolls
/// through Limits then Usage; page two is Jev usage. Shared by the notch
/// island and the menu-bar popover.
struct DashboardView: View {
    let model: IslandModel
    let jev: JevUsageMonitor
    /// Shown pages, the open one and each page's range.
    @Bindable var selection: DashboardSelection
    /// Header height; in the island this is the camera's height so the header
    /// sits in the menu-bar band beside it.
    var headerHeight: CGFloat = 28
    /// Width of the camera between the header's halves (0: no camera).
    var cameraGap: CGFloat = 0
    /// Fixed height of the scrolling page (see `PageSizing.viewport`).
    var pageHeight: CGFloat
    /// Offscreen snapshots can't render scroll views; they get the page clipped
    /// to `pageHeight`, shifted up by this offset instead.
    var snapshotOffset: CGFloat?
    var openSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var page: DashboardPage { selection.pages.current }

    var body: some View {
        VStack(spacing: DashboardMetrics.spacing) {
            header.frame(height: headerHeight)
            pages
        }
        .frame(width: DashboardMetrics.contentWidth)
        .foregroundStyle(.white)
    }

    /// Queue-specific problem, shown above recorded data.
    private var queueIssue: String? {
        let issue = UsageState.issue(connection: model.connection, usageAvailable: model.usageAvailable,
                                     queueError: model.usageQueueError)
        switch issue {
        case .queueUnavailable?, .queueError?: return issue?.message
        default: return nil
        }
    }

    private var limitsEmptyText: String {
        switch model.connection {
        case .needsKey: "Add the key to see account limits."
        case .connected, .connecting: "No accounts logged in to the proxy."
        default: "Account limits appear once the proxy can be read."
        }
    }

    // MARK: Header

    private var header: some View {
        let side = (DashboardMetrics.contentWidth - cameraGap) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(page.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                PageDots(selection: selection)
                Spacer(minLength: 0)
            }
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: cameraGap)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if page == .usage {
                    ConnectionDot(state: model.connection)
                        .padding(.trailing, 3)
                        .help("Updated \(Format.ago(model.lastUpdated))")
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                    model.refreshNow()
                    jev.refresh()
                }
                IconButton(symbol: "gearshape.fill", help: "Settings", action: openSettings)
            }
            .frame(width: side, alignment: .trailing)
        }
    }

    // MARK: Page

    /// Only the current page is in the hierarchy. Each page enters from and
    /// leaves to its own side (AI usage left, Jev right), so both pages slide
    /// the same way whichever direction you switch.
    @ViewBuilder private var pages: some View {
        ZStack(alignment: .top) {
            switch page {
            case .usage:
                ScrollingPage(height: pageHeight, snapshotOffset: snapshotOffset) { usageContent(now: $0) }
                    .transition(pageTransition(from: .leading))
            case .jev:
                ScrollingPage(height: pageHeight, snapshotOffset: snapshotOffset) { _ in
                    JevPage(jev: jev, range: $selection.jevRange)
                }
                .transition(pageTransition(from: .trailing))
            }
        }
        .frame(height: pageHeight, alignment: .top)
        .clipped()
    }

    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge)
    }

    @ViewBuilder private func usageContent(now: Date) -> some View {
        // Both sections always render; a connection problem adds a card on top
        // and each section explains its own empty state.
        VStack(spacing: DashboardMetrics.spacing) {
            if let problem = model.connection.problem, model.accounts.isEmpty {
                ProblemView(title: problem.title, detail: problem.detail, transient: model.connection.isTransient,
                            retry: { model.refreshNow() }, openSettings: openSettings)
            } else if let problem = model.connection.problem {
                ProblemBanner(title: problem.title, transient: model.connection.isTransient,
                              action: model.connection.isTransient ? { model.refreshNow() } : openSettings)
            }
            let active = model.accounts.filter { $0.health != .disabled }.count
            SectionHeader(title: "Limits") {
                if active > 0 {
                    Text(active == 1 ? "1 account" : "\(active) accounts")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.secondary)
                }
            }
            LimitsPage(accounts: model.accounts, now: now,
                       emptyText: limitsEmptyText)
            let range = selection.usageRange
            SectionHeader(title: "Usage") { RangePicker(range: $selection.usageRange) }
                .padding(.top, 4)
            UsagePage(report: model.usageReports[range], series: model.usageSeries[range],
                      state: model.usageState(for: range), queueIssue: queueIssue)
        }
    }
}

// MARK: - Pages

/// A page of fixed height whatever its content: short pages just don't
/// scroll; long ones fade at the edge where more is out of view.
private struct ScrollingPage<Content: View>: View {
    var height: CGFloat
    /// Offscreen snapshots can't render scroll views; they get the page
    /// clipped to `height`, shifted up by this offset instead.
    var snapshotOffset: CGFloat?
    @ViewBuilder var content: (Date) -> Content

    @State private var moreBelow = false
    @State private var moreAbove = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let content = content(context.date)
            if let snapshotOffset {
                // No fade here: the snapshot can't tell whether more is below.
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -snapshotOffset)
                    .frame(height: height, alignment: .top)
                    .clipped()
            } else {
                ScrollView(.vertical) { content }
                    .frame(height: height)
                    .scrollIndicators(.automatic)
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: EdgeState.self) { geo in
                        EdgeState(above: geo.contentOffset.y > 2,
                                  below: geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 2)
                    } action: { _, edges in
                        withAnimation(.easeOut(duration: 0.15)) {
                            moreAbove = edges.above
                            moreBelow = edges.below
                        }
                    }
                    .mask(EdgeFade(top: moreAbove, bottom: moreBelow))
            }
        }
    }
}

private struct EdgeState: Equatable {
    var above: Bool
    var below: Bool
}

/// One dot per shown page beside the title; the current one is a short bar.
/// A single shown page keeps its dot so the header doesn't shift.
private struct PageDots: View {
    let selection: DashboardSelection

    var body: some View {
        let page = selection.pages.current
        HStack(spacing: -4) {
            ForEach(selection.pages.shown, id: \.self) { item in
                Button {
                    selection.show(item)
                } label: {
                    Capsule()
                        .fill(.white.opacity(item == page ? 0.85 : 0.28))
                        .frame(width: item == page ? 10 : 4, height: 4)
                        .frame(minWidth: 14, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title) page")
                .accessibilityAddTraits(item == page ? .isSelected : [])
            }
        }
        .help(selection.pages.shown.count > 1
              ? "Swipe sideways with two fingers, or click a dot, to switch pages"
              : "Turn the other page on in Settings")
    }
}

// MARK: - Header pieces

/// Fades the page's edges where more content is scrolled out of view.
private struct EdgeFade: View {
    var top: Bool
    var bottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
        }
    }
}


struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 2)
    }
}

private struct IconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundStyle(hovering ? .white : Theme.secondary)
                .background(Color.white.opacity(hovering ? 0.14 : 0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Cards

struct CardChrome<Content: View>: View {
    /// Stretch to the row's height (cards side by side share one height).
    var fill = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(.white.opacity(0.065),
                        in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
    }
}

private struct LimitsPage: View {
    var accounts: [Account]
    var now: Date
    var emptyText: String

    var body: some View {
        let active = accounts.filter { $0.health != .disabled }
        if active.isEmpty {
            EmptyNote(symbol: "person.crop.circle.badge.questionmark", text: emptyText)
        } else {
            let rows = stride(from: 0, to: active.count, by: 2).map { Array(active[$0..<min($0 + 2, active.count)]) }
            VStack(spacing: DashboardMetrics.spacing) {
                ForEach(rows, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: DashboardMetrics.spacing) {
                        ForEach(row) { AccountCard(account: $0, now: now) }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AccountCard: View {
    var account: Account
    var now: Date

    /// Two rows fit: the shortest window and whichever longer one binds first.
    private var windows: [QuotaWindow] {
        guard let first = account.windows.first else { return [] }
        let longer = account.windows.dropFirst().max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
        return [first, longer].compactMap { $0 }
    }

    var body: some View {
        CardChrome(fill: true) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ProviderGlyph(provider: account.provider)
                    Text(account.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let chip = account.health.chip {
                        Chip(text: chip.text, tint: chip.tint)
                    } else if let plan = account.plan {
                        Chip(text: plan.capitalized, tint: account.provider.tint)
                    }
                }
                .frame(height: 17)
                if windows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 5) {
                        ForEach(windows) { LimitRow(window: $0, tint: account.provider.tint, now: now) }
                    }
                }
                Text(footer)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyText: String {
        switch account.provider {
        case .claude, .codex: "No reading yet. It appears after the next request."
        default: "\(account.provider.displayName) doesn't report quota."
        }
    }

    private var footer: String {
        var parts = ["\(account.requestsLastHour) req/h"]
        if account.failedLastHour > 0 { parts.append("\(account.failedLastHour) failed") }
        switch account.quotaSource {
        case .live(let at): parts.append("live \(Format.ago(at, now: now))")
        case .headers(let at): parts.append("seen \(Format.ago(at, now: now))")
        case .none: break
        }
        return parts.joined(separator: " · ")
    }
}

private struct UsagePage: View {
    var report: UsageReport?
    var series: UsageSeries?
    var state: UsageState
    /// A usage-queue problem to mention above recorded data (connection
    /// problems already have their banner at the top).
    var queueIssue: String?

    var body: some View {
        VStack(spacing: DashboardMetrics.spacing) {
            CardChrome {
                VStack(alignment: .leading, spacing: 5) {
                    if let report, state == .data {
                        if let queueIssue {
                            Label(queueIssue, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        totals(report)
                        if let series { TokenChart(series: series).padding(.top, 2) }
                        if report.isPartial { partialNote(report) }
                    } else if let message = state.message {
                        Label(message, systemImage: symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if state == .empty, let report, let since = report.trackingSince {
                            Text("Recording since \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute())).")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
            if state == .data, let report {
                HStack(alignment: .top, spacing: DashboardMetrics.spacing) {
                    BreakdownCard(title: "By account", symbol: "person.2.fill",
                                  rows: report.byAccount.map { BreakdownRow(id: $0.id, name: $0.label, provider: $0.provider, totals: $0.totals) })
                    BreakdownCard(title: "By model", symbol: "cpu",
                                  rows: report.byModel.map {
                                      BreakdownRow(id: $0.model, name: $0.model, provider: nil,
                                                   totals: UsageTotals(requests: $0.requests, failed: $0.failed,
                                                                       inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                                                                       totalTokens: $0.totalTokens))
                                  })
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch state {
        case .needsKey, .keyRejected: "key.fill"
        case .proxyUnreachable, .queueUnavailable, .queueError, .pollFailed: "exclamationmark.triangle.fill"
        case .waiting: "hourglass"
        case .empty, .data: "tray"
        }
    }

    private func totals(_ report: UsageReport) -> some View {
        let t = report.totals
        return VStack(alignment: .leading, spacing: 1) {
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
    }

    private func partialNote(_ report: UsageReport) -> some View {
        let since = report.trackingSince.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
        return Label(since.map { "Recorded since \($0), and only while the app runs." }
                     ?? "Nothing recorded yet for this range.",
                     systemImage: "clock.badge.exclamationmark")
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.warning.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

}

/// Today / 7d / 30d.
struct RangePicker: View {
    @Binding var range: UsageRange

    var body: some View {
        HStack(spacing: 1) {
            ForEach(UsageRange.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.emphasis) { range = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(item == range ? .black : Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item == range ? Color.white : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.spokenTitle)
                .accessibilityAddTraits(item == range ? .isSelected : [])
            }
        }
        .padding(1.5)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

private struct BreakdownRow: Identifiable {
    var id: String
    var name: String
    var provider: Provider?
    var totals: UsageTotals
}

/// A ranked list: name and tokens on one line, a hairline share bar under it.
private struct BreakdownCard: View {
    var title: String
    var symbol: String
    var rows: [BreakdownRow]
    private let limit = 7
    @State private var showAll = false

    var body: some View {
        CardChrome(fill: true) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.secondary).frame(width: 14)
                    Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                    Text("tok · req").font(.system(size: 8.5)).foregroundStyle(Theme.tertiary)
                }
                .frame(height: 15)
                let peak = max(rows.map(\.totals.totalTokens).max() ?? 1, 1)
                ForEach(rows.prefix(showAll ? rows.count : limit)) { row in
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            if let provider = row.provider {
                                Image(systemName: provider.symbol)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(provider.tint)
                                    .frame(width: 10)
                            }
                            Text(row.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.tokens(row.totals.totalTokens))
                                .font(Theme.number(10, .medium))
                            Text("\(row.totals.requests)")
                                .font(Theme.number(9.5, .regular))
                                .foregroundStyle(row.totals.failed > 0 ? Theme.warning : Theme.tertiary)
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                        Meter(value: Double(row.totals.totalTokens) / Double(peak),
                              tint: (row.provider?.tint ?? .white).opacity(0.8), height: 2)
                    }
                    .help("\(row.name): \(row.totals.totalTokens) tokens (in \(row.totals.inputTokens), out \(row.totals.outputTokens)), \(row.totals.requests) requests" + (row.totals.failed > 0 ? ", \(row.totals.failed) failed" : ""))
                    .accessibilityElement(children: .combine)
                }
                if rows.count > limit {
                    Button(showAll ? "Show fewer" : "+\(rows.count - limit) more") {
                        withAnimation(Theme.emphasis) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

// MARK: - States

struct EmptyNote: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// The whole page when there's nothing else to show.
private struct ProblemView: View {
    var title: String
    var detail: String
    var transient: Bool
    var retry: () -> Void
    var openSettings: () -> Void

    var body: some View {
        let tint = transient ? Theme.danger : Theme.warning
        CardChrome {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: transient ? "bolt.horizontal.circle.fill" : "key.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                PillButton(title: transient ? "Retry" : "Settings", action: transient ? retry : openSettings)
            }
        }
    }
}

/// One-line warning above stale content (e.g. the proxy went down after a good poll).
private struct ProblemBanner: View {
    var title: String
    var transient: Bool
    var action: () -> Void

    var body: some View {
        let tint = transient ? Theme.danger : Theme.warning
        HStack(spacing: 6) {
            Image(systemName: transient ? "bolt.horizontal.circle.fill" : "key.fill")
                .font(.system(size: 10))
            Text(title + " · showing last reading").font(.system(size: 10, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            PillButton(title: transient ? "Retry" : "Settings", action: action)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PillButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.14), in: Capsule())
    }
}

extension UsageRange {
    var spokenTitle: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .halfYear: "Last 6 months"
        }
    }
}
