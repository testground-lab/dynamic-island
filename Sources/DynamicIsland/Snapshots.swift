import AppKit
import IslandCore
import SwiftUI

/// `DynamicIsland --snapshot <dir>` renders the demo island (idle, Limits,
/// Usage per range, menu-bar icon and popover) to PNGs without opening any window. Used for
/// design review; needs no Screen Recording permission.
@MainActor
enum Snapshots {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = IslandModel.demo()
        let notch = CGSize(width: 220, height: 38)

        // First run: no key stored, nothing recorded (an in-memory, keyless model).
        let suite = "dev.ksotis.dynamic-island.snapshot"
        let keylessDefaults = UserDefaults(suiteName: suite) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keyless = IslandModel(keyStore: InMemoryKeyStore(), defaults: keylessDefaults,
                                  store: UsageStore(url: nil))
        let states: [(String, IslandModel, IslandPresentation, CGFloat, UsageRange)] = [
            ("idle", model, .collapsed, 0, .today),
            ("idle-hover", model, .emphasized, 0, .today),
            ("open-top", model, .expanded(byHover: false), 0, .today),
            ("usage-today", model, .expanded(byHover: false), 236, .today),
            ("usage-7d", model, .expanded(byHover: false), 236, .week),
            ("usage-30d", model, .expanded(byHover: false), 236, .month),
            ("open-no-key", keyless, .expanded(byHover: false), 0, .today),
        ]
        for (name, model, presentation, offset, range) in states {
            let ui = IslandUIState()
            ui.notchSize = notch
            ui.presentation = presentation
            ui.usageRange = range
            ui.isSnapshot = true
            ui.snapshotOffset = offset
            let expanded = ui.isExpanded
            let view = IslandView(model: model, ui: ui, onTap: {}, openSettings: {}, quit: {})
                .frame(width: IslandMetrics.panelSize.width, height: expanded ? ui.panelHeight : 60)
                .background(Color(white: 0.82)) // stand-in for a light desktop
            try write(view, to: directory.appendingPathComponent(name + ".png"))
        }
        // The status icon is a template image: AppKit tints it for the menu bar.
        if let icon = MenuBarController.icon(for: model.connection) {
            for (name, background, ink) in [("menubar-light", Color(white: 0.93), Color.black),
                                              ("menubar-dark", Color(white: 0.15), Color.white)] {
                try write(Image(nsImage: icon).renderingMode(.template).foregroundStyle(ink)
                    .frame(width: 28, height: 22).background(background),
                          to: directory.appendingPathComponent(name + ".png"))
            }
        }
        try write(PopoverDashboard(model: model, snapshotOffset: 0, openSettings: {}, range: .today),
                  to: directory.appendingPathComponent("menubar-popover.png"))
    }

    private static func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
