import AppKit
import IslandCore
import SwiftUI

/// Fallback for displays without a notch: a menu-bar item that shows the same
/// compact summary and opens the dashboard in a popover.
@MainActor
final class MenuBarController: NSObject {
    private let model: IslandModel
    private let selection: DashboardSelection
    private var gesture = ScrollGestureRecognizer()
    private var scrollMonitor: Any?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let openSettings: () -> Void
    private let quit: () -> Void
    private var alive = true

    init(model: IslandModel, jev: JevUsageMonitor, selection: DashboardSelection,
         openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.selection = selection
        self.openSettings = openSettings
        self.quit = quit
        super.init()

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView:
            PopoverDashboard(model: model, jev: jev, selection: selection, openSettings: { [weak self] in
                self?.popover.performClose(nil)
                openSettings()
            })
            .environment(\.colorScheme, .dark))

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
        installSwipeMonitor()
    }

    /// Sideways two-finger swipes in the popover switch pages, as on the island.
    private func installSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.popover.isShown, event.window === self.popover.contentViewController?.view.window
            else { return event }
            let phase = IslandCore.ScrollPhase(event)
            let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            let action = self.gesture.feed(pull: Double(event.scrollingDeltaY) * sign,
                                           sideways: Double(event.scrollingDeltaX) * sign,
                                           time: event.timestamp, phase: phase,
                                           precise: event.hasPreciseScrollingDeltas,
                                           expanded: true, verticalAllowed: false)
            guard let action, action == .nextPage || action == .previousPage else { return event }
            let target = self.selection.page.applying(action)
            if target != self.selection.page { withAnimation(Theme.page) { self.selection.page = target } }
            return nil
        }
    }

    func tearDown() {
        alive = false
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Re-renders the button whenever anything it reads changes.
    private func render() {
        guard alive else { return }
        withObservationTracking {
            item.button?.image = Self.icon(for: model.connection)
            item.button?.setAccessibilityLabel(model.connection.problem.map { "CLIProxy: " + $0.title } ?? "CLIProxy dashboard")
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    /// A template symbol (so it follows light and dark menu bars) when all is
    /// well; a coloured one when something needs attention.
    static func icon(for connection: ConnectionState) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard connection.problem != nil else {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }
        let color: NSColor = connection.isTransient ? NSColor(Theme.danger) : NSColor(Theme.warning)
        let image = NSImage(systemSymbolName: connection.isTransient ? "bolt.horizontal.circle.fill" : "key.fill",
                            accessibilityDescription: nil)?
            .withSymbolConfiguration(config.applying(.init(paletteColors: [color])))
        image?.isTemplate = false
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Dynamic Island", action: #selector(quitApp), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate() // otherwise the transient popover may not close on outside clicks
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func refresh() { model.refreshNow() }
    @objc private func settings() { openSettings() }
    @objc private func quitApp() { quit() }
}

/// The dashboard in the popover: no camera, so the header is one row.
struct PopoverDashboard: View {
    let model: IslandModel
    let jev: JevUsageMonitor
    @Bindable var selection: DashboardSelection
    var snapshotOffset: CGFloat?
    var openSettings: () -> Void

    static let headerHeight: CGFloat = 22
    static let padding: CGFloat = 12

    var body: some View {
        DashboardView(model: model, jev: jev, page: $selection.page, range: $selection.usageRange, jevRange: $selection.jevRange,
                      headerHeight: Self.headerHeight,
                      pageHeight: PageSizing.viewport(total: Theme.openHeight, header: Self.headerHeight,
                                                      spacing: DashboardMetrics.spacing, chrome: 2 * Self.padding),
                      snapshotOffset: snapshotOffset, openSettings: openSettings)
            .padding(.horizontal, 14)
            .padding(.vertical, Self.padding)
            .background(.black)
    }
}
