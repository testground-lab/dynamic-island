import IslandCore
import SwiftUI

/// Page and range choices of the dashboard. One instance lives as long as the
/// app and is shared by the island and the menu-bar popover, so a display
/// change that swaps one for the other keeps them. Only the shown pages
/// (Settings) outlive the app.
@MainActor @Observable
final class DashboardSelection {
    private(set) var pages: DashboardPages
    var usageRange: UsageRange = .today
    var jevRange: UsageRange = .today
    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults` keeps the shown pages; nil keeps them in memory only (snapshots).
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        pages = defaults.map(DashboardPages.init(defaults:)) ?? DashboardPages()
    }

    /// Opens `page` (dot click, --page), or the first shown page if it's hidden.
    func show(_ page: DashboardPage) {
        withAnimation(Theme.page) { pages.show(page) }
    }

    /// Steps to the next or previous shown page; false when there is none.
    func apply(_ action: ScrollGestureAction) -> Bool {
        var stepped = pages
        guard stepped.apply(action) else { return false }
        withAnimation(Theme.page) { pages = stepped }
        return true
    }

    /// Settings: shows or hides a page (never the last one) and saves it.
    func setEnabled(_ page: DashboardPage, _ isOn: Bool) {
        withAnimation(Theme.page) { pages.setEnabled(page, isOn) }
        if let defaults { pages.save(to: defaults) }
    }
}

/// UI-only state shared between the notch window controller and the views.
@MainActor @Observable
final class IslandUIState {
    let selection: DashboardSelection
    var presentation: IslandPresentation = .collapsed
    var floating = false
    var topInset: CGFloat = 0
    var headerHeight: CGFloat { floating ? 28 : notchSize.height }
    /// Size of the hardware notch, or the floating idle pill.
    var notchSize = CGSize(width: 190, height: 32)
    /// Island frame in window coordinates (top-left origin), used for hit-testing.
    var islandFrame: CGRect = .zero
    var panelHeight: CGFloat = IslandMetrics.panelSize.height
    /// Snapshot only: render the page scrolled down by this much.
    var snapshotOffset: CGFloat?
    /// Offscreen rendering (no scroll views, see `Snapshots`).
    var isSnapshot = false

    init(selection: DashboardSelection = DashboardSelection()) {
        self.selection = selection
    }

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
    /// The open island's fixed height plus room for the spring overshoot; the
    /// rest of the panel is transparent and click-through.
    static let panelSize = CGSize(width: expandedWidth + 64, height: Theme.openHeight + 60)
}

struct IslandView: View {
    let model: IslandModel
    let jev: JevUsageMonitor
    let ui: IslandUIState
    /// Any click on the island; the controller decides what it means
    /// (open, pin, or close when it lands on the camera area of the open header).
    var onTap: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        let expanded = ui.isExpanded
        let shape = IslandOutline(floating: ui.floating)
        VStack(spacing: 0) {
            Color.clear.frame(height: ui.topInset)
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
            .background(shape.fill(.black))
            .clipShape(shape)
            .contentShape(shape)
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
        let shoulder = NotchShape.shoulder(height: 200)
        return DashboardView(model: model, jev: jev, selection: ui.selection,
                             headerHeight: ui.headerHeight,
                             cameraGap: ui.floating ? 0 : ui.notchSize.width,
                             pageHeight: PageSizing.viewport(total: Theme.openHeight, header: ui.headerHeight,
                                                             spacing: DashboardMetrics.spacing,
                                                             chrome: IslandMetrics.bottomInset),
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

/// Real camera shoulders stay unchanged; external displays use a rounded black pill.
private struct IslandOutline: Shape {
    var floating: Bool

    func path(in rect: CGRect) -> Path {
        if floating {
            return RoundedRectangle(cornerRadius: min(rect.height / 2, 22), style: .continuous).path(in: rect)
        }
        return NotchShape().path(in: rect)
    }
}
