import IslandCore
import SwiftUI

/// UI-only state shared between the notch window controller and the views.
@MainActor @Observable
final class IslandUIState {
    var presentation: IslandPresentation = .collapsed
    var tab: IslandTab = .limits
    /// Size of the hardware notch (or a stand-in on displays without one).
    var notchSize = CGSize(width: 190, height: 32)
    /// Island frame in window coordinates (top-left origin), used for hit-testing.
    var islandFrame: CGRect = .zero
    var panelHeight: CGFloat = IslandMetrics.panelSize.height
    /// Offscreen rendering (no scroll views, see `Snapshots`).
    var isSnapshot = false

    var isExpanded: Bool {
        if case .expanded = presentation { return true }
        return false
    }
}

enum IslandMetrics {
    static let expandedWidth: CGFloat = 480
    /// Horizontal inset of content from the open island's body edge.
    static let contentInset: CGFloat = 14
    static let bottomInset: CGFloat = 14
    /// Collapsed wings beside the camera: as wide as their content, within these bounds.
    static let wingRange: ClosedRange<CGFloat> = 44...80
    /// Hover "pulse": growth per side and downward.
    static let emphasisGrowth = CGSize(width: 10, height: 5)
    /// Big enough for the open island plus its spring overshoot; the rest of
    /// the panel is transparent and click-through.
    static let panelSize = CGSize(width: expandedWidth + 64, height: 420)
}

struct IslandView: View {
    let model: IslandModel
    let ui: IslandUIState
    /// Click on the island body (opens a closed island, pins a hover-opened one).
    var onTap: () -> Void
    /// Click on the camera area of the open header (closes it).
    var onCameraTap: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        let expanded = ui.isExpanded
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    expandedContent
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                } else {
                    CollapsedStrip(model: model, notchSize: ui.notchSize, emphasized: ui.presentation == .emphasized)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
            }
            .background(NotchShape().fill(.black))
            .clipShape(NotchShape())
            .contentShape(NotchShape())
            .simultaneousGesture(TapGesture().onEnded(onTap))
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
        .animation(expanded ? Theme.open : Theme.close, value: expanded)
        .animation(Theme.emphasis, value: ui.presentation == .emphasized)
        .environment(\.colorScheme, .dark)
    }

    private var expandedContent: some View {
        @Bindable var ui = ui
        let shoulder = NotchShape.shoulder(height: 200)
        return DashboardView(model: model, tab: $ui.tab,
                             headerHeight: ui.notchSize.height,
                             cameraGap: ui.notchSize.width,
                             maxContentHeight: min(DashboardMetrics.contentBudget,
                                                   ui.panelHeight - ui.notchSize.height - 40),
                             scrollable: !ui.isSnapshot,
                             onCameraTap: onCameraTap,
                             openSettings: openSettings)
            .padding(.horizontal, shoulder + IslandMetrics.contentInset)
            .padding(.bottom, IslandMetrics.bottomInset)
            .frame(width: IslandMetrics.expandedWidth)
    }
}

/// The closed island: exactly as tall as the camera, with a wing on each side.
/// Left: quota ring + % left of the busiest account; right: requests per hour.
/// Wings share one width (the wider content's), so the camera stays centred.
struct CollapsedStrip: View {
    let model: IslandModel
    var notchSize: CGSize
    var emphasized: Bool
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    private static let edgeInset: CGFloat = 9

    var body: some View {
        let growth = emphasized ? IslandMetrics.emphasisGrowth : .zero
        let height = notchSize.height + growth.height
        let wing = min(max(max(leftWidth, rightWidth) + Self.edgeInset, IslandMetrics.wingRange.lowerBound),
                       IslandMetrics.wingRange.upperBound) + growth.width
        let shoulder = NotchShape.shoulder(height: height)
        HStack(spacing: 0) {
            left
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftWidth = $0 }
                .padding(.leading, Self.edgeInset)
                .frame(width: wing, alignment: .leading)
            Color.clear.frame(width: notchSize.width)
            right
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightWidth = $0 }
                .padding(.trailing, Self.edgeInset)
                .frame(width: wing, alignment: .trailing)
        }
        .frame(height: notchSize.height)
        .frame(height: height, alignment: .top)
        .padding(.horizontal, shoulder)
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CLIProxy")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the dashboard")
    }

    @ViewBuilder private var left: some View {
        if model.connection.problem != nil {
            Image(systemName: model.connection.isTransient ? "bolt.horizontal.circle.fill" : "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.connection.isTransient ? Theme.danger : Theme.warning)
        } else if let account = model.featuredAccount, let window = account.bindingWindow {
            HStack(spacing: 4) {
                QuotaRing(window: window, tint: account.provider.tint, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text(Format.percent(window.remainingFraction))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(window.tint(base: account.provider.tint))
                    .contentTransition(.numericText())
            }
        } else if let account = model.featuredAccount {
            ProviderGlyph(provider: account.provider, size: 12)
        } else {
            ConnectionDot(state: model.connection)
        }
    }

    private var right: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(model.requestsLastHour)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .contentTransition(.numericText())
            Text("/h").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .opacity(model.connection.problem == nil ? 1 : 0.45)
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
}
