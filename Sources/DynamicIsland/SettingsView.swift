import AppKit
import IslandCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: IslandModel
    let selection: DashboardSelection
    var displayChanged: () -> Void
    @State private var displays = NSScreen.screens.compactMap(\.displayInfo)
    @State private var displayPreference = DisplayPreference(defaults: .standard)
    @State private var keyDraft = ""
    @State private var baseURLDraft = ""
    @State private var message: (text: String, isError: Bool)?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var revertingLoginToggle = false
    @AppStorage(NotchController.openOnHoverKey) private var openOnHover = false

    var body: some View {
        Form {
            Section {
                SecureField("Management key", text: $keyDraft, prompt: Text(model.hasKey ? "Stored in Keychain — paste to replace" : "Paste management key"))
                    .onSubmit(saveKey)
                HStack {
                    Text(model.hasKey ? "A key is stored in your login Keychain." : "No key stored yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.hasKey {
                        Button("Remove", role: .destructive, action: removeKey)
                    }
                    Button("Save Key", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("CLIProxyAPI management key")
            } footer: {
                Text("The plaintext of `management.secret-key` you set in the proxy config (the config only keeps its hash). It never leaves this Mac and is only sent to the address below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Proxy") {
                HStack {
                    TextField("Base URL", text: $baseURLDraft, prompt: Text(BaseURLValidator.defaultBaseURL))
                        .onSubmit(applyBaseURL)
                    Button("Apply", action: applyBaseURL)
                        .disabled(baseURLDraft == model.baseURLString)
                }
                Text("Plain http is only allowed for localhost; use https for anything else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Usage history comes from the proxy's usage queue, which hands each record to whoever reads it first and keeps it about a minute. While the CLIProxyAPI web panel (or another tool) also reads the queue, the two split the records and both undercount.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        ConnectionDot(state: model.connection)
                        Text(statusText)
                    }
                }
            }

            Section("Display") {
                Picker("Show island on", selection: $displayPreference) {
                    Text("Automatic").tag(DisplayPreference.automatic)
                    ForEach(displays) { display in
                        Text(display.name + (display.isBuiltin ? " (built-in)" : ""))
                            .tag(displayTag(display))
                    }
                    if case .display(let id, let name) = displayPreference,
                       !displays.contains(where: { $0.id == id }) {
                        Text(name + " (not connected)").tag(displayPreference)
                    }
                }
                .onChange(of: displayPreference) { _, preference in
                    preference.save(to: .standard)
                    displayChanged()
                }
                Text("Automatic uses a notched display, or the menu bar if none is connected. A chosen display without a notch shows a floating pill. If disconnected, Automatic is used until it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pages") {
                ForEach(DashboardPage.allCases, id: \.self) { page in
                    Toggle(page.title, isOn: Binding(get: { selection.pages.isEnabled(page) },
                                                     set: { selection.setEnabled(page, $0) }))
                        .disabled(selection.pages.isLocked(page))
                }
                Text("Hidden pages keep collecting data in the background. One page always stays on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Open the island on hover", isOn: $openOnHover)
                Text(openOnHover
                     ? "Opens after resting on the island for a moment and closes when the pointer leaves. A click keeps it open."
                     : "Click the island, or swipe down on it with two fingers, to open. Click elsewhere, press Esc or swipe up on its top row to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Fetch live quota from Claude / Codex every 5 min", isOn: $model.liveQuotaEnabled)
                Text("Asks the proxy to call each provider's usage endpoint with the account's own token. When off, quota comes only from rate-limit headers the proxy has seen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if revertingLoginToggle {
                            revertingLoginToggle = false
                            return
                        }
                        if let error = LaunchAtLogin.set(enabled) {
                            message = (error, true)
                            if launchAtLogin != LaunchAtLogin.isEnabled {
                                revertingLoginToggle = true
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                    }
                if LaunchAtLogin.needsApproval {
                    HStack {
                        Text("Allow Dynamic Island in System Settings › Login Items to finish.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if !LaunchAtLogin.isAvailable {
                    Text("Available when running the bundled DynamicIsland.app (scripts/bundle.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? .red : .green)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { baseURLDraft = model.baseURLString }
        .onDisappear { keyDraft = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = NSScreen.screens.compactMap(\.displayInfo)
        }
    }

    private func displayTag(_ display: DisplayInfo) -> DisplayPreference {
        // A connected display can be renamed; UUID, not its saved name, identifies it.
        if case .display(let id, _) = displayPreference, id == display.id { return displayPreference }
        return .display(id: display.id, name: display.name)
    }

    private var statusText: String {
        switch model.connection {
        case .connected(let at): "Connected · \(Format.ago(at))"
        case .connecting: "Connecting…"
        case .needsKey: "Waiting for a key"
        case .keyRejected: "Key rejected (401)"
        case .proxyDown: "Proxy down"
        case .failed(let detail): detail
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.saveKey(key)
            keyDraft = ""
            message = ("Key saved to Keychain.", false)
        } catch {
            message = ("Couldn't save the key to Keychain.", true)
        }
    }

    private func removeKey() {
        do {
            try model.clearKey()
            message = ("Key removed.", false)
        } catch {
            message = ("Couldn't remove the key from Keychain.", true)
        }
    }

    private func applyBaseURL() {
        guard let url = BaseURLValidator.validate(baseURLDraft) else {
            message = ("Invalid address. Use http://127.0.0.1:<port> or an https URL.", true)
            return
        }
        if !Self.isLoopback(url) && !confirmRemote(host: url.host() ?? url.absoluteString) { return }
        if model.applyBaseURL(baseURLDraft) {
            baseURLDraft = model.baseURLString
            message = ("Proxy address updated.", false)
        } else {
            message = ("Invalid address. Use http://127.0.0.1:<port> or an https URL.", true)
        }
    }
}

extension SettingsView {
    static func isLoopback(_ url: URL) -> Bool {
        // Foundation may keep IPv6 brackets in host().
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// The management key goes to whatever host is configured; make sending it
    /// off this Mac a deliberate choice.
    private func confirmRemote(host: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send the management key to \(host)?"
        alert.informativeText = "Every poll includes your management key. Only continue if you run CLIProxyAPI on that host."
        alert.addButton(withTitle: "Use \(host)")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum LaunchAtLogin {
    /// SMAppService only works from a real .app bundle.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { isAvailable && SMAppService.mainApp.status == .requiresApproval }

    /// Returns an error message on failure.
    @MainActor static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return nil }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }
}

/// Accessory apps can't reliably take focus (activation is cooperative since
/// macOS 14), so the app becomes a regular app while Settings is open and goes
/// back to having no Dock icon when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: IslandModel
    private let selection: DashboardSelection
    private let displayChanged: () -> Void

    init(model: IslandModel, selection: DashboardSelection, displayChanged: @escaping () -> Void) {
        self.model = model
        self.selection = selection
        self.displayChanged = displayChanged
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model, selection: selection, displayChanged: displayChanged))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Dynamic Island Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
