import AppKit
import IslandCore

/// Launch flags (for development and screenshots):
///   --demo      render bundled fixtures, no network, no Keychain
///   --expanded  keep the island expanded
///   --menubar   force the menu-bar fallback even on a notched display
///   --snapshot <dir>  render demo PNGs and exit
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = Set(CommandLine.arguments)
    private var model: IslandModel!
    private var settings: SettingsWindowController!
    private var notch: NotchController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            do {
                try Snapshots.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApp.setActivationPolicy(.accessory) // no Dock icon, also when run unbundled

        if arguments.contains("--demo") {
            model = IslandModel.demo()
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DynamicIsland", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let aggregator = UsageAggregator(persistenceURL: support.appendingPathComponent("usage.json"))
            model = IslandModel(keyStore: KeychainKeyStore(), aggregator: aggregator)
            model.start()
        }
        settings = SettingsWindowController(model: model)

        layoutForScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
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
                notch = NotchController(model: model, screen: screen, pinnedExpanded: arguments.contains("--expanded"),
                                        openSettings: openSettings, quit: quit)
            }
        } else {
            notch?.tearDown()
            notch = nil
            if menuBar == nil {
                menuBar = MenuBarController(model: model, openSettings: openSettings, quit: quit)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
