import AppKit
import IslandCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: IslandModel
    @State private var keyDraft = ""
    @State private var baseURLDraft = ""
    @State private var message: (text: String, isError: Bool)?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

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
                        .keyboardShortcut(.defaultAction)
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
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        ConnectionDot(state: model.connection)
                        Text(statusText)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Fetch live quota from Claude / Codex every 5 min", isOn: $model.liveQuotaEnabled)
                Text("Asks the proxy to call each provider's usage endpoint with the account's own token. When off, quota comes only from rate-limit headers the proxy has seen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if let error = LaunchAtLogin.set(enabled) {
                            message = (error, true)
                            launchAtLogin = LaunchAtLogin.isEnabled
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
        if model.applyBaseURL(baseURLDraft) {
            baseURLDraft = model.baseURLString
            message = ("Proxy address updated.", false)
        } else {
            message = ("Invalid address. Use http://127.0.0.1:<port> or an https URL.", true)
        }
    }
}

enum LaunchAtLogin {
    /// SMAppService only works from a real .app bundle.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

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

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: IslandModel

    init(model: IslandModel) { self.model = model }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Dynamic Island Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
