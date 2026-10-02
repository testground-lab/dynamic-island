import IslandCore
import SwiftUI

/// UI-only state shared between the notch window controller and the views.
@MainActor @Observable
final class IslandUIState {
    var presentation: IslandPresentation = .collapsed
    var usageRange: UsageRange = .today
    /// Size of the hardware notch (or a stand-in on displays without one).
    var notchSize = CGSize(width: 190, height: 32)
    /// Island frame in window coordinates (top-left origin), used for hit-testing.
    var islandFrame: CGRect = .zero
    var panelHeight: CGFloat = IslandMetrics.panelSize.height
    var maxContentHeight: CGFloat = DashboardMetrics.defaultMaxContentHeight
    /// Snapshot only: render the page scrolled down by this much.
    var snapshotOffset: CGFloat?
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
    /// Hover "pulse": growth per side and downward.
    static let emphasisGrowth = CGSize(width: 10, height: 5)
    /// Default panel size. The real height is set per screen in
    /// `NotchController.place(on:)` (page cap + header + room for the spring
    /// overshoot); the rest of the panel is transparent and click-through.
    static let panelSize = CGSize(width: expandedWidth + 64, height: 420)
}

struct IslandView: View {
    let model: IslandModel
    let ui: IslandUIState
    /// Any click on the island; the controller decides what it means
    /// (open, pin, or close when it lands on the camera area of the open header).
    var onTap: () -> Void
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
                    IdleNotch(problem: model.connection.problem?.title, notchSize: ui.notchSize, emphasized: ui.presentation == .emphasized)
                        .accessibilityAction { onTap() }
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
        return DashboardView(model: model, range: $ui.usageRange,
                             headerHeight: ui.notchSize.height,
                             cameraGap: ui.notchSize.width,
                             maxContentHeight: ui.maxContentHeight,
                             snapshotOffset: ui.isSnapshot ? (ui.snapshotOffset ?? 0) : nil,
                             openSettings: openSettings)
            .padding(.horizontal, shoulder + IslandMetrics.contentInset)
            .padding(.bottom, IslandMetrics.bottomInset)
            .frame(width: IslandMetrics.expandedWidth)
    }
}

/// The closed island: nothing but the camera cutout itself, so at rest it is
/// invisible. Hovering nudges it a little wider and taller (the cue that it
/// can be clicked open); it shows no live data.
struct IdleNotch: View {
    var problem: String? = nil
    var notchSize: CGSize
    var emphasized: Bool

    var body: some View {
        let growth = emphasized ? IslandMetrics.emphasisGrowth : .zero
        Color.clear
            .frame(width: notchSize.width + 2 * growth.width, height: notchSize.height + growth.height)
            .accessibilityElement()
            .accessibilityLabel("CLIProxy dashboard")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(problem ?? "")
            .accessibilityHint("Opens quota and usage")
    }
}
