import AppKit
import IslandCore
import SwiftUI

extension NSScreen {
    /// The camera housing's frame in screen coordinates, if this display has one.
    var notchFrame: CGRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        // Width-only math: correct whether the auxiliary areas are reported in
        // global or screen-local coordinates.
        let height = safeAreaInsets.top
        return CGRect(x: frame.minX + left.width, y: frame.maxY - height,
                      width: frame.width - left.width - right.width, height: height)
    }

    static var notched: NSScreen? { screens.first { $0.notchFrame != nil } }
}

/// Borderless, non-activating, always-on-top panel that never steals focus.
final class NotchPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reports pointer movement over the panel even while the
/// app is inactive, and lets the first click hit buttons directly.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onMouseMoved: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMoved?()
    }
}

/// Owns the island panel on a notched display: positions it over the notch,
/// tracks the pointer, expands on hover and keeps the transparent rest of the
/// panel click-through.
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let ui = IslandUIState()
    private var monitors: [Any] = []
    private var pendingChange: DispatchWorkItem?
    private let pinnedExpanded: Bool

    init(model: IslandModel, screen: NSScreen, pinnedExpanded: Bool = false,
         openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.pinnedExpanded = pinnedExpanded
        panel = NotchPanel(contentRect: .zero)
        let root = IslandView(model: model, ui: ui, openSettings: openSettings, quit: quit)
        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.onMouseMoved = { [weak self] in self?.pointerMoved() }
        place(on: screen)
        if pinnedExpanded {
            ui.isExpanded = true
            panel.ignoresMouseEvents = false
        }
        panel.orderFrontRegardless()
        installMonitors()
    }

    func place(on screen: NSScreen) {
        let notch = screen.notchFrame ?? CGRect(x: screen.frame.midX - 95, y: screen.frame.maxY - 32, width: 190, height: 32)
        ui.notchSize = notch.size
        // Shorter screens (e.g. "Larger Text" scaling) get a shorter panel.
        ui.panelHeight = min(IslandMetrics.panelSize.height, screen.frame.height - 40)
        let size = CGSize(width: IslandMetrics.panelSize.width, height: ui.panelHeight)
        let frame = CGRect(x: (notch.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    func tearDown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pendingChange?.cancel()
        panel.orderOut(nil)
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(local) }
    }

    /// Island rect in screen coordinates, stretched up to the top edge so the
    /// pointer pressed against the top of the screen still counts as inside.
    private var islandScreenRect: CGRect {
        let f = ui.islandFrame
        let window = panel.frame
        let rect = CGRect(x: window.minX + f.minX, y: window.maxY - f.maxY, width: f.width, height: f.height)
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: window.maxY - rect.minY)
    }

    private func pointerMoved() {
        let inside = islandScreenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard !pinnedExpanded, inside != ui.isExpanded || pendingChange != nil else { return }
        pendingChange?.cancel()
        guard inside != ui.isExpanded else {
            pendingChange = nil
            return
        }
        // Small delay to open (avoid flicker when the pointer passes through the
        // menu bar), longer one to close (forgive brief exits).
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.ui.isExpanded = inside
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.08 : 0.35), execute: work)
    }
}
