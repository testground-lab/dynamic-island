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
            DashboardView(model: model, headerHeight: 26, maxContentHeight: 520, openSettings: { [weak self] in
                self?.popover.performClose(nil)
                openSettings()
            })
            .frame(width: IslandMetrics.expandedWidth - 40)
            .padding(18)
            .background(.black)
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

/// Compact pill for the menu bar: ring + remaining %, then requests/hour.
struct MenuBarLabel: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: 5) {
            if model.connection.problem != nil {
                Image(systemName: model.connection.isTransient ? "bolt.horizontal.circle.fill" : "key.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.connection.isTransient ? Theme.danger : Theme.warning)
            } else if let account = model.featuredAccount {
                QuotaRing(window: account.bindingWindow, tint: account.provider.tint, lineWidth: 2.2)
                    .frame(width: 11, height: 11)
                Text(Format.percent(account.bindingWindow?.remainingFraction)).font(Theme.number(11))
            }
            Text("\(model.requestsLastHour)/h")
                .font(Theme.number(11, .medium))
                .foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(.black, in: Capsule())
    }
}
