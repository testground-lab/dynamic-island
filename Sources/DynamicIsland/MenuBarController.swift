import AppKit
import IslandCore
import SwiftUI

/// Fallback for displays without a notch: a menu-bar item that shows the same
/// compact summary and opens the dashboard in a popover.
@MainActor
final class MenuBarController: NSObject {
    private let model: IslandModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let openSettings: () -> Void
    private let quit: () -> Void
    private var alive = true

    init(model: IslandModel, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.quit = quit
        super.init()

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView:
            PopoverDashboard(model: model, openSettings: { [weak self] in
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
    }

    func tearDown() {
        alive = false
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Re-renders the button whenever anything it reads changes.
    private func render() {
        guard alive else { return }
        withObservationTracking {
            let renderer = ImageRenderer(content: MenuBarLabel(model: model).environment(\.colorScheme, .dark))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            if let image = renderer.nsImage {
                image.isTemplate = false
                item.button?.image = image
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
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

/// The menu-bar icon: a plain gauge, tinted only when something needs attention.
/// Like the idle island, it carries no live numbers.
struct MenuBarLabel: View {
    let model: IslandModel

    var body: some View {
        let problem = model.connection.problem != nil
        Image(systemName: problem ? (model.connection.isTransient ? "bolt.horizontal.circle.fill" : "key.fill")
                                  : "gauge.with.dots.needle.67percent")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(problem ? (model.connection.isTransient ? Theme.danger : Theme.warning) : Color.white)
            .frame(width: 22, height: 18)
            .accessibilityLabel(problem ? "CLIProxy: " + (model.connection.problem?.title ?? "") : "CLIProxy dashboard")
    }
}

/// The dashboard in the popover: no camera, so the header is one row.
struct PopoverDashboard: View {
    let model: IslandModel
    var scrollable = true
    var openSettings: () -> Void
    @State var tab: IslandTab = .limits
    @State var range: UsageRange = .today

    var body: some View {
        DashboardView(model: model, tab: $tab, range: $range, headerHeight: 22, scrollable: scrollable, openSettings: openSettings)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.black)
    }
}
