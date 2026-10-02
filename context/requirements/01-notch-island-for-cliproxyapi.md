# Notch dynamic island for CLIProxyAPI

**Statement:** A native macOS app: a black "dynamic island" hanging from the MacBook notch, for the local CLIProxyAPI gateway (http://127.0.0.1:8317). On displays without a notch it falls back to a menu-bar item with the same panel. Launch-at-login option, no Dock icon.

**Source:** Initial brief, 2026-10-02.

**Status:** current

**Where in code:** `Sources/DynamicIsland/NotchController.swift`, `MenuBarController.swift`, `main.swift`, `SettingsView.swift` (launch at login)
