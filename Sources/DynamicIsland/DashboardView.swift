import IslandCore
import SwiftUI

/// The expanded content: account quota cards + per-model usage.
/// Shared by the notch island and the menu-bar popover.
struct DashboardView: View {
    let model: IslandModel
    /// Height of the top band reserved for the header (the notch's height in
    /// the island, so header items sit in the "wings" beside the camera).
    var headerHeight: CGFloat = 28
    var maxContentHeight: CGFloat = 470
    /// Off for offscreen snapshots: ImageRenderer can't draw scroll views.
    var scrollable = true
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header.frame(height: headerHeight)
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
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ConnectionDot(state: model.connection)
            Text("CLIProxy")
                .font(.system(size: 12, weight: .semibold))
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(Format.ago(model.lastUpdated, now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refreshNow() }
            IconButton(symbol: "gearshape.fill", help: "Settings") { openSettings() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let problem = model.connection.problem {
                ProblemCard(title: problem.title, detail: problem.detail, openSettings: openSettings)
            }
            if !model.accounts.isEmpty {
                let active = model.accounts.filter { $0.health != .disabled }
                let disabled = model.accounts.count - active.count
                SectionTitle(title: "Accounts",
                             trailing: disabled > 0 ? "\(active.count) active · \(disabled) disabled" : "\(active.count)")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 2),
                          alignment: .leading, spacing: 10) {
                    ForEach(active) { AccountCard(account: $0) }
                }
            }
            UsageSection(usage: model.usage, available: model.usageAvailable)
        }
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(hovering ? .white : Theme.secondary)
                .background(Color.white.opacity(hovering ? 0.14 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct SectionTitle: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            Spacer()
            if let trailing {
                Text(trailing).font(Theme.number(10, .medium)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

private struct ProblemCard: View {
    var title: String
    var detail: String
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Settings", action: openSettings)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warning.opacity(0.25)))
    }
}

struct AccountCard: View {
    var account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProviderGlyph(provider: account.provider, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HealthBadge(health: account.health)
            if account.windows.isEmpty {
                Text(emptyQuotaText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(account.windows.prefix(3)) { QuotaBar(window: $0, tint: account.provider.tint) }
            }
            HStack(spacing: 6) {
                Text("\(account.requestsLastHour) req/h")
                    .font(Theme.number(10, .medium))
                    .foregroundStyle(Theme.secondary)
                if account.failedLastHour > 0 {
                    Text("\(account.failedLastHour) failed")
                        .font(Theme.number(10, .medium))
                        .foregroundStyle(Theme.danger)
                }
                Spacer(minLength: 0)
                if let source = sourceText {
                    Text(source).font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    private var subtitle: String {
        [account.provider.displayName, account.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")
    }

    private var emptyQuotaText: String {
        switch account.provider {
        case .claude, .codex: "No quota reading yet. It appears after the next request or live fetch."
        default: "This provider doesn't report quota."
        }
    }

    private var sourceText: String? {
        switch account.quotaSource {
        case .live(let at): "live · \(Format.ago(at))"
        case .headers(let at): "seen \(Format.ago(at))"
        case .none: nil
        }
    }
}

private struct UsageSection: View {
    var usage: UsageSummary
    var available: Bool
    @State private var range: Range = .hour

    enum Range: String, CaseIterable { case hour = "Last hour", today = "Today" }

    var body: some View {
        let rows = range == .hour ? usage.lastHour : usage.today
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                SectionTitle(title: "Usage by model")
                Spacer()
                RangeToggle(selection: $range)
            }
            if !available {
                note("This proxy doesn't expose the usage queue, so per-model usage is unavailable.")
            } else if rows.isEmpty {
                note(emptyText)
            } else {
                totals(rows)
                let maxTokens = max(rows.map(\.totalTokens).max() ?? 1, 1)
                VStack(spacing: 6) {
                    ForEach(rows.prefix(6)) { ModelRow(usage: $0, share: Double($0.totalTokens) / Double(maxTokens)) }
                }
                if rows.count > 6 {
                    Text("+ \(rows.count - 6) more models").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var emptyText: String {
        if let since = usage.trackingSince {
            return "No requests \(range == .hour ? "in the last hour" : "today") since tracking started \(since.formatted(.dateTime.hour().minute()))."
        }
        return "Waiting for the first requests."
    }

    private func totals(_ rows: [ModelUsage]) -> some View {
        let tokens = rows.reduce(0) { $0 + $1.totalTokens }
        let requests = rows.reduce(0) { $0 + $1.requests }
        let failed = rows.reduce(0) { $0 + $1.failed }
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Stat(value: Format.tokens(tokens), label: "tokens")
            Stat(value: "\(requests)", label: "requests")
            if failed > 0 { Stat(value: "\(failed)", label: "failed", tint: Theme.danger) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Stat: View {
    var value: String
    var label: String
    var tint: Color = .white

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.number(17, .bold)).foregroundStyle(tint)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct RangeToggle: View {
    @Binding var selection: UsageSection.Range
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageSection.Range.allCases, id: \.self) { range in
                Text(range.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(selection == range ? .black : Theme.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background {
                        if selection == range {
                            Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(Theme.spring) { selection = range } }
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct ModelRow: View {
    var usage: ModelUsage
    var share: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(usage.model)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.55)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * share, 3))
                }
            }
            .frame(height: 5)
            Text(Format.tokens(usage.totalTokens))
                .font(Theme.number(11))
                .frame(width: 46, alignment: .trailing)
            Text("\(usage.requests) req")
                .font(Theme.number(10, .medium))
                .foregroundStyle(usage.failed > 0 ? Theme.warning : Theme.tertiary)
                .frame(width: 50, alignment: .trailing)
                .help(usage.failed > 0 ? "\(usage.failed) failed" : "")
        }
        .animation(Theme.spring, value: share)
    }
}
