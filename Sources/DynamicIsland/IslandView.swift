import IslandCore
import SwiftUI

/// UI-only state shared between the notch window controller and the views.
@MainActor @Observable
final class IslandUIState {
    var isExpanded = false
    /// Size of the hardware notch (or a stand-in on displays without one).
    var notchSize = CGSize(width: 190, height: 32)
    /// Island frame in window coordinates (top-left origin), used for hit-testing.
    var islandFrame: CGRect = .zero
    var panelHeight: CGFloat = IslandMetrics.panelSize.height
    /// Offscreen rendering (no scroll views, see `Snapshots`).
    var isSnapshot = false
}

enum IslandMetrics {
    static let wing: CGFloat = 56
    static let expandedWidth: CGFloat = 580
    static let collapsedFlare: CGFloat = 7
    static let expandedFlare: CGFloat = 14
    static let collapsedRadius: CGFloat = 11
    static let expandedRadius: CGFloat = 28
    /// Panel size: big enough for the expanded island; everything outside the
    /// island is transparent and click-through.
    static let panelSize = CGSize(width: expandedWidth + 2 * expandedFlare + 40, height: 760)
}

struct IslandView: View {
    let model: IslandModel
    let ui: IslandUIState
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        let expanded = ui.isExpanded
        let flare = expanded ? IslandMetrics.expandedFlare : IslandMetrics.collapsedFlare
        let shape = NotchShape(topRadius: flare,
                               bottomRadius: expanded ? IslandMetrics.expandedRadius : IslandMetrics.collapsedRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    DashboardView(model: model,
                                  headerHeight: ui.notchSize.height,
                                  maxContentHeight: ui.panelHeight - ui.notchSize.height - 60,
                                  scrollable: !ui.isSnapshot,
                                  openSettings: openSettings)
                        .frame(width: IslandMetrics.expandedWidth - 40)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                .animation(Theme.spring.delay(0.05)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else {
                    CollapsedSummary(model: model, notchSize: ui.notchSize)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .padding(.horizontal, flare)
            .background(shape.fill(.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
            .contentShape(shape)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.islandFrame = $0 }
            .contextMenu {
                Button("Refresh Now") { model.refreshNow() }
                Button("Settings…", action: openSettings)
                Divider()
                Button("Quit Dynamic Island", action: quit)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.spring, value: expanded)
        .environment(\.colorScheme, .dark)
    }
}

/// What shows while collapsed: quota ring of the busiest account on the left
/// wing, requests in the last hour on the right wing. The middle is hidden
/// behind the camera housing.
struct CollapsedSummary: View {
    let model: IslandModel
    var notchSize: CGSize

    var body: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: IslandMetrics.wing, alignment: .leading)
            Color.clear.frame(width: notchSize.width)
            rightWing.frame(width: IslandMetrics.wing, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .frame(height: notchSize.height)
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CLIProxy")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if let problem = model.connection.problem { return problem.title }
        var parts: [String] = []
        if let account = model.featuredAccount, let window = account.bindingWindow {
            parts.append("\(account.provider.displayName) \(account.label), \(window.label) \(Format.percent(window.remainingFraction)) left")
        }
        parts.append("\(model.requestsLastHour) requests in the last hour")
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var leftWing: some View {
        if model.connection.problem != nil {
            Image(systemName: model.connection.isTransient ? "bolt.horizontal.circle.fill" : "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.connection.isTransient ? Theme.danger : Theme.warning)
                .padding(.leading, 10)
        } else if let account = model.featuredAccount {
            HStack(spacing: 5) {
                QuotaRing(window: account.bindingWindow, tint: account.provider.tint, lineWidth: 2.5)
                    .frame(width: 13, height: 13)
                Text(Format.percent(account.bindingWindow?.remainingFraction))
                    .font(Theme.number(11))
                    .foregroundStyle(account.bindingWindow?.tint(base: .white) ?? Theme.secondary)
            }
            .padding(.leading, 10)
            .help("\(account.provider.displayName) · \(account.label)")
        } else {
            ConnectionDot(state: model.connection).padding(.leading, 12)
        }
    }

    private var rightWing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(model.requestsLastHour)").font(Theme.number(11))
            Text("/h").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .padding(.trailing, 10)
        .opacity(model.connection.problem == nil ? 1 : 0.4)
    }
}
