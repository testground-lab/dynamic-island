import IslandCore
import SwiftUI

enum IslandTab: String, CaseIterable {
    case limits = "Limits", usage = "Usage"

    var next: IslandTab {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var previous: IslandTab {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

enum DashboardMetrics {
    /// Content column of the open island (480 wide minus shoulders and insets).
    static let contentWidth: CGFloat = 424
    static let spacing: CGFloat = 6
    static let cardRadius: CGFloat = 14
    /// Pages scroll past this.
    static let contentBudget: CGFloat = 214
}

/// The open island's content: a header row beside the camera, then one page.
/// Shared by the notch island and the menu-bar popover.
struct DashboardView: View {
    let model: IslandModel
    @Binding var tab: IslandTab
    /// Header height; in the island this is the camera's height so the header
    /// sits in the menu-bar band beside it.
    var headerHeight: CGFloat = 28
    /// Width of the camera between the header's halves (0: no camera).
    var cameraGap: CGFloat = 0
    var maxContentHeight: CGFloat = DashboardMetrics.contentBudget
    /// Off for offscreen snapshots: ImageRenderer can't draw scroll views.
    var scrollable = true
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: DashboardMetrics.spacing) {
            header.frame(height: headerHeight)
            page
        }
        .frame(width: DashboardMetrics.contentWidth)
        .foregroundStyle(.white)
    }

    // MARK: Header

    private var header: some View {
        let side = (DashboardMetrics.contentWidth - cameraGap) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                PageDots(tab: $tab)
                Spacer(minLength: 0)
            }
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: cameraGap)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ConnectionDot(state: model.connection)
                    .padding(.trailing, 3)
                    .help("Updated \(Format.ago(model.lastUpdated))")
                IconButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refreshNow() }
                IconButton(symbol: "gearshape.fill", help: "Settings", action: openSettings)
            }
            .frame(width: side, alignment: .trailing)
        }
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let content = pageContent(now: context.date)
            if scrollable {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView(showsIndicators: false) { content }
                }
                .frame(maxHeight: maxContentHeight)
            } else {
                content
            }
        }
    }

    @ViewBuilder private func pageContent(now: Date) -> some View {
        if let problem = model.connection.problem, model.accounts.isEmpty {
            ProblemView(title: problem.title, detail: problem.detail, transient: model.connection.isTransient,
                        retry: { model.refreshNow() }, openSettings: openSettings)
        } else {
            VStack(spacing: DashboardMetrics.spacing) {
                if let problem = model.connection.problem {
                    ProblemBanner(title: problem.title, transient: model.connection.isTransient,
                                  action: model.connection.isTransient ? { model.refreshNow() } : openSettings)
                }
                switch tab {
                case .limits: LimitsPage(accounts: model.accounts, now: now)
                case .usage: UsagePage(usage: model.usage, available: model.usageAvailable)
                }
            }
            .id(tab)
            .transition(.opacity)
        }
    }
}

// MARK: - Header pieces

private struct PageDots: View {
    @Binding var tab: IslandTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(IslandTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.emphasis) { tab = item }
                } label: {
                    Capsule()
                        .fill(.white.opacity(item == tab ? 0.9 : 0.25))
                        .frame(width: item == tab ? 10 : 4, height: 4)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
        }
        .help("Swipe sideways with two fingers to switch pages")
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

private struct CardChrome<Content: View>: View {
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

    var body: some View {
        let active = accounts.filter { $0.health != .disabled }
        if active.isEmpty {
            EmptyNote(symbol: "person.crop.circle.badge.questionmark", text: "No accounts logged in to the proxy.")
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
    var usage: UsageSummary
    var available: Bool
    @State private var today = false

    var body: some View {
        let rows = today ? usage.today : usage.lastHour
        CardChrome {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "cpu").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 17)
                    Text("Models").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(Theme.emphasis) { today.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            Text(today ? "Today" : "Last hour")
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Switch between the last hour and today")
                }
                .frame(height: 17)
                if !available {
                    note("This proxy doesn't expose its usage queue.")
                } else if rows.isEmpty {
                    note(usage.trackingSince.map { "No requests \(today ? "today" : "in the last hour") since \($0.formatted(.dateTime.hour().minute()))." }
                         ?? "Waiting for the first requests.")
                } else {
                    totals(rows)
                    let peak = max(rows.map(\.totalTokens).max() ?? 1, 1)
                    VStack(spacing: 5) {
                        ForEach(rows.prefix(8)) { ModelRow(usage: $0, share: Double($0.totalTokens) / Double(peak)) }
                    }
                    if rows.count > 8 {
                        Text("+\(rows.count - 8) more").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }

    private func totals(_ rows: [ModelUsage]) -> some View {
        let tokens = rows.reduce(0) { $0 + $1.totalTokens }
        let requests = rows.reduce(0) { $0 + $1.requests }
        let failed = rows.reduce(0) { $0 + $1.failed }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Format.tokens(tokens)).font(Theme.number(18, .medium)).contentTransition(.numericText())
            Text("tokens · \(requests) req")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.secondary)
            if failed > 0 {
                Text("· \(failed) failed").font(.system(size: 9.5)).foregroundStyle(Theme.warning)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(2)
    }
}

private struct ModelRow: View {
    var usage: ModelUsage
    var share: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(usage.model)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: max(3, 150 * share), height: 4)
                .frame(width: 150, alignment: .leading)
            Text(Format.tokens(usage.totalTokens))
                .font(Theme.number(10, .medium))
                .frame(minWidth: 38, alignment: .trailing)
            Text("\(usage.requests)")
                .font(Theme.number(9.5, .regular))
                .foregroundStyle(usage.failed > 0 ? Theme.warning : Theme.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
                .help(usage.failed > 0 ? "\(usage.requests) requests, \(usage.failed) failed" : "\(usage.requests) requests")
        }
        .frame(height: 14)
        .animation(Theme.spring, value: share)
    }
}

// MARK: - States

private struct EmptyNote: View {
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
