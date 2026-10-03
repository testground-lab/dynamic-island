import AppKit
import IslandCore

/// Launch flags (for development and screenshots):
///   --demo      render bundled fixtures, no network, no Keychain
///   --expanded  keep the island expanded
///   --menubar   force the menu-bar fallback even on a notched display
///   --page jev  open on the Jev page
///   --jev-dir <dir>  read Jev usage logs from this folder instead of the router's (also with --demo)
///   --snapshot <dir>  render demo PNGs and exit
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = Set(CommandLine.arguments)
    private var model: IslandModel!
    private var jev: JevUsageMonitor!
    private let selection = DashboardSelection()
    private var settings: SettingsWindowController!
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private var screenObserver: NSObjectProtocol?

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
        if let page = Self.value(after: "--page").flatMap(DashboardPage.init(rawValue:)) { selection.page = page }
        settings = SettingsWindowController(model: model)

        layoutForScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutForScreens() }
        }

        if model.connection == .needsKey { settings.show() }
    }

    /// Island on the notched display when there is one; menu-bar item otherwise.
    private func layoutForScreens() {
        let openSettings: () -> Void = { [weak self] in self?.settings.show() }
        let quit: () -> Void = { NSApp.terminate(nil) }
        let screen = arguments.contains("--menubar") ? nil : NSScreen.notched

        if let screen {
            menuBar?.tearDown()
            menuBar = nil
            if let notch {
                notch.place(on: screen)
            } else {
                notch = NotchController(model: model, jev: jev, selection: selection, screen: screen,
                                        pinnedExpanded: arguments.contains("--expanded"),
                                        openSettings: openSettings, quit: quit)
            }
        } else {
            notch?.tearDown()
            notch = nil
            if menuBar == nil {
                menuBar = MenuBarController(model: model, jev: jev, selection: selection, openSettings: openSettings, quit: quit)
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
        model?.stop()
        jev?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
