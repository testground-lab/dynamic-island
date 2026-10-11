import AppKit
import IslandCore

/// Launch flags (for development and screenshots):
///   --demo      render bundled fixtures, no network, no Keychain
///   --expanded  keep the island expanded
///   --menubar   force the menu-bar fallback even on a notched display
///   --page <usage|jev|projects>  open on a shown page (see Settings)
///   --range <today|week|month|halfYear>  start every page on this range
///   --jev-dir <dir>  read Jev usage logs from this folder instead of the router's (also with --demo)
///   --snapshot <dir>  render demo PNGs and exit
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = Set(CommandLine.arguments)
    private var model: IslandModel!
    private var jev: JevUsageMonitor!
    private var projects: ProjectUsageMonitor!
    private let selection = DashboardSelection(defaults: .standard)
    private var settings: SettingsWindowController!
    private var notch: NotchController?
    private var islands: [UUID: NotchController] = [:] // All displays, keyed by display UUID
    private var menuBar: MenuBarController?
    private var screenObserver: NSObjectProtocol?
    private var pointerMonitors: [Any] = []
    private var settleWork: DispatchWorkItem?
    private var relocation = DisplayRelocation(current: .menuBar)
    private var pointerDisplayID: UUID?
    private var hasLaidOut = false
    private var alive = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do {
                    try await Snapshots.render(to: directory)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        NSApp.setActivationPolicy(.accessory) // no Dock icon, also when run unbundled
        NSApp.mainMenu = Self.makeMainMenu()

        if arguments.contains("--demo") {
            model = IslandModel.demo()
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DynamicIsland", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let store = UsageStore(url: support.appendingPathComponent("usage.sqlite"))
            model = IslandModel(keyStore: KeychainKeyStore(), store: store)
            model.start()
        }
        // --demo shows a fixture unless --jev-dir points at real logs.
        if let path = Self.value(after: "--jev-dir") {
            jev = JevUsageMonitor(directory: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            jev = arguments.contains("--demo") ? JevUsageMonitor.demo()
                : JevUsageMonitor(directory: JevUsageMonitor.defaultDirectory)
        }
        jev.start()
        projects = arguments.contains("--demo") ? ProjectUsageMonitor.demo() : ProjectUsageMonitor()
        projects.start()
        if let page = Self.value(after: "--page").flatMap(DashboardPage.init(rawValue:)) { selection.show(page) }
        if let range = Self.value(after: "--range").flatMap(UsageRange.init(rawValue:)) {
            selection.usageRange = range
            selection.jevRange = range
            selection.projectsRange = range
        }
        settings = SettingsWindowController(model: model, selection: selection, displayChanged: { [weak self] in self?.layoutForScreens() })

        layoutForScreens()
        installPointerMonitors()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutForScreens() }
        }

        if model.connection == .needsKey { settings.show() }
    }

    private func resolvedTarget() -> DisplayTarget {
        pointerDisplayID = DisplayGeometry.containing(NSEvent.mouseLocation, displays: NSScreen.displayFrames,
                                                      fallback: pointerDisplayID)
        return DisplayTarget.resolve(DisplayPreference(defaults: .standard),
                                     displays: NSScreen.screens.compactMap(\.displayInfo),
                                     pointerDisplayID: pointerDisplayID,
                                     forceMenuBar: arguments.contains("--menubar"))
    }

    /// Topology and Settings invalidate maturity even when the UUID remains the same.
    private func layoutForScreens() {
        guard alive else { return }
        settleWork?.cancel()
        settleWork = nil
        relocation.invalidate()
        let screens = NSScreen.screens
        if let ids = DisplayTarget.allDisplayIDs(DisplayPreference(defaults: .standard),
                                                 displays: screens.compactMap(\.displayInfo),
                                                 forceMenuBar: arguments.contains("--menubar")) {
            layoutAllDisplays(screens, ids: ids)
            return
        }
        if !islands.isEmpty {
            // Leaving All displays, or it lost every display: the single island starts afresh at its target.
            islands.values.forEach { $0.tearDown() }
            islands.removeAll()
            hasLaidOut = false
        }
        let target = resolvedTarget()
        let available = Set(screens.compactMap { $0.displayInfo?.id })
        if !hasLaidOut {
            hasLaidOut = true
            relocation.reset(to: target)
            present(target)
        } else if relocation.recoverIfDisconnected(to: target, available: available) {
            notch?.dismissForRemovedScreen()
            notch?.tearDown()
            notch = nil
            present(target)
        } else {
            // Same-screen geometry can change without a UUID change (resolution/menu/Dock).
            if let id = relocation.current.displayID, let screen = screens.first(where: { $0.displayInfo?.id == id }) {
                notch?.place(on: screen)
            }
            routePointer()
        }
    }

    /// One independent island per display. Nothing follows the pointer, so none moves or disappears.
    private func layoutAllDisplays(_ screens: [NSScreen], ids: [UUID]) {
        notch?.tearDown()
        notch = nil
        menuBar?.tearDown()
        menuBar = nil
        let byID = Dictionary(screens.compactMap { screen in screen.displayInfo.map { ($0.id, screen) } },
                              uniquingKeysWith: { first, _ in first })
        let diff = DisplayDiff(current: Set(islands.keys), available: ids)
        for id in diff.removed {
            islands[id]?.dismissForRemovedScreen()
            islands.removeValue(forKey: id)?.tearDown()
        }
        for id in diff.kept { if let screen = byID[id] { islands[id]?.place(on: screen) } }
        for id in diff.added { if let screen = byID[id] { islands[id] = makeIsland(on: screen, didClose: {}) } }
    }

    /// Owned by the app, so pointer following also works while Automatic is a menu-bar item.
    private func installPointerMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.routePointer() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.routePointer()
            return event
        }) { pointerMonitors.append(local) }
    }

    private func routePointer() {
        guard alive, islands.isEmpty else { return }
        let token = relocation.observe(resolvedTarget())
        if relocation.candidate == nil {
            settleWork?.cancel()
            settleWork = nil
        }
        guard let token else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alive, self.relocation.revision == token else { return }
            // A delayed callback must not apply a target the pointer has already left.
            self.routePointer()
            guard self.relocation.revision == token else { return }
            self.settleWork = nil
            if let target = self.relocation.settle(token, expanded: self.notch?.isExpanded ?? false) {
                self.present(target)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DisplayRelocation.settleDelay, execute: work)
    }

    private func islandDidClose() {
        guard alive else { return }
        routePointer()
        if let target = relocation.applyIfReady(expanded: notch?.isExpanded ?? false) { present(target) }
    }

    private func makeIsland(on screen: NSScreen, didClose: @escaping () -> Void) -> NotchController {
        NotchController(model: model, jev: jev, projects: projects, selection: selection, screen: screen,
                        pinnedExpanded: arguments.contains("--expanded"), didClose: didClose,
                        openSettings: { [weak self] in self?.settings.show() }, quit: { NSApp.terminate(nil) })
    }

    private func present(_ target: DisplayTarget) {
        let openSettings: () -> Void = { [weak self] in self?.settings.show() }
        let quit: () -> Void = { NSApp.terminate(nil) }
        let screen = NSScreen.screens.first { $0.displayInfo?.id == target.displayID }
        if let screen, target.displayID != nil {
            menuBar?.tearDown()
            menuBar = nil
            if let notch {
                notch.place(on: screen)
            } else {
                notch = makeIsland(on: screen, didClose: { [weak self] in self?.islandDidClose() })
            }
        } else {
            notch?.tearDown()
            notch = nil
            if menuBar == nil {
                menuBar = MenuBarController(model: model, jev: jev, projects: projects, selection: selection, openSettings: openSettings, quit: quit)
            }
        }
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Accessory apps show no menu bar, but the key equivalents of the main menu
    /// still work — without an Edit menu, Cmd-V can't paste the key into Settings.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Dynamic Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    func applicationWillTerminate(_ notification: Notification) {
        alive = false
        relocation.invalidate()
        settleWork?.cancel()
        settleWork = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        notch?.tearDown()
        islands.values.forEach { $0.tearDown() }
        menuBar?.tearDown()
        model?.stop()
        jev?.stop()
        projects?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
