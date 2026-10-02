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

/// Borderless, non-activating, always-on-top panel. It only takes key focus
/// (for Escape) when the island is opened by a click; the app never activates.
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

    override var canBecomeKey: Bool { true }
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
/// turns pointer, click, key and scroll events into `IslandInteraction`
/// events, runs the effects it asks for (timers, haptics, focus) and keeps
/// the transparent rest of the panel click-through.
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let ui = IslandUIState()
    private var interaction: IslandInteraction
    private var gesture = ScrollGestureRecognizer()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var timers: [IslandTimer: DispatchWorkItem] = [:]
    private let pinnedExpanded: Bool

    init(model: IslandModel, screen: NSScreen, pinnedExpanded: Bool = false,
         openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.pinnedExpanded = pinnedExpanded
        interaction = IslandInteraction(openOnHover: UserDefaults.standard.bool(forKey: Self.openOnHoverKey))
        panel = NotchPanel(contentRect: .zero)
        var tap: () -> Void = {}
        var cameraTap: () -> Void = {}
        let root = IslandView(model: model, ui: ui, onTap: { tap() }, onCameraTap: { cameraTap() },
                              openSettings: openSettings, quit: quit)
        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        place(on: screen)
        tap = { [weak self] in self?.send { $0.clicked() } }
        cameraTap = { [weak self] in self?.send { $0.toggle() } }
        hosting.onMouseMoved = { [weak self] in self?.pointerMoved() }
        if pinnedExpanded {
            ui.presentation = .expanded(byHover: false)
            panel.ignoresMouseEvents = false
        }
        panel.orderFrontRegardless()
        installMonitors()
    }

    static let openOnHoverKey = "openOnHover"

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
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        panel.orderOut(nil)
    }

    // MARK: Events -> interaction

    private func send(_ event: (inout IslandInteraction) -> [IslandEffect]) {
        guard !pinnedExpanded else { return }
        interaction.openOnHover = UserDefaults.standard.bool(forKey: Self.openOnHoverKey)
        let effects = event(&interaction)
        if ui.presentation != interaction.presentation {
            if !interaction.isExpanded, panel.isKeyWindow { panel.resignKey() }
            ui.presentation = interaction.presentation
        }
        effects.forEach(run)
    }

    private func run(_ effect: IslandEffect) {
        switch effect {
        case .schedule(let timer, let delay):
            timers[timer]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.timers[timer] = nil
                self?.send { $0.timerFired(timer) }
            }
            timers[timer] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .cancel(let timer):
            timers.removeValue(forKey: timer)?.cancel()
        case .haptic:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .takeFocus:
            panel.makeKey()
        }
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(local) }

        // A click anywhere else closes the open island.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.interaction.isExpanded, !self.isPointerInside else { return }
                self.send { $0.dismiss() }
            }
        }) { monitors.append(global) }

        // Escape closes; two-finger scrolls open/close and switch pages.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53, event.window === self.panel, self.interaction.isExpanded else { return event }
                self.send { $0.dismiss() }
                return nil
            }
            return self.scrolled(event) ? nil : event
        }) { monitors.append(local) }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.send { $0.otherAppActivated() }
            }
        })
    }

    /// Feeds a scroll event to the gesture recogniser; true if it was used.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard event.window === panel, isPointerInside else { return false }
        let phase: IslandCore.ScrollPhase
        if !event.momentumPhase.isEmpty { phase = .momentum }
        else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { phase = .began }
        else if event.phase.contains(.ended) || event.phase.contains(.cancelled) { phase = .ended }
        else if event.phase.isEmpty { phase = .none }
        else { phase = .changed }
        // Normalise so positive = fingers moving down / right, whatever the
        // natural-scrolling setting; wheels get a coarser step.
        let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 10
        let expanded = interaction.isExpanded
        // Open pages may scroll vertically; there only the header band closes.
        let inHeader = NSEvent.mouseLocation.y >= panel.frame.maxY - ui.notchSize.height
        let action = gesture.feed(pull: Double(event.scrollingDeltaY) * sign * scale,
                                  swipe: Double(event.scrollingDeltaX) * sign * scale,
                                  time: event.timestamp, phase: phase,
                                  precise: event.hasPreciseScrollingDeltas,
                                  expanded: expanded, verticalAllowed: !expanded || inHeader)
        guard let action else { return !expanded } // nothing else scrolls on the closed island
        switch action {
        case .open, .close:
            send { $0.gesture(action) }
            return true
        case .next, .previous:
            guard expanded else { return false }
            withAnimation(Theme.emphasis) { ui.tab = ui.tab.next }
            return true
        }
    }

    // MARK: Pointer

    /// Island rect in screen coordinates, stretched up to the top edge so the
    /// pointer pressed against the top of the screen still counts as inside.
    private var islandScreenRect: CGRect {
        let f = ui.islandFrame
        let window = panel.frame
        let rect = CGRect(x: window.minX + f.minX, y: window.maxY - f.maxY, width: f.width, height: f.height)
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: window.maxY - rect.minY)
    }

    private var isPointerInside: Bool {
        islandScreenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        let inside = isPointerInside
        panel.ignoresMouseEvents = !inside
        guard inside != interaction.pointerInside else { return }
        send { inside ? $0.pointerEntered() : $0.pointerExited() }
    }
}
