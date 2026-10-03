import AppKit
import IslandCore
import SwiftUI

/// `DynamicIsland --snapshot <dir>` renders the demo island (idle, Limits,
/// Usage per range, menu-bar icon and popover) to PNGs without opening any window. Used for
/// design review; needs no Screen Recording permission.
@MainActor
enum Snapshots {
    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = IslandModel.demo()
        let jev = JevUsageMonitor.demo()
        let noJev = JevUsageMonitor(url: nil)
        await noJev.reload()
        let notch = CGSize(width: 220, height: 38)

        // First run: no key stored, nothing recorded (an in-memory, keyless model).
        let suite = "dev.ksotis.dynamic-island.snapshot"
        let keylessDefaults = UserDefaults(suiteName: suite) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keyless = IslandModel(keyStore: InMemoryKeyStore(), defaults: keylessDefaults,
                                  store: UsageStore(url: nil))
        let open = IslandPresentation.expanded(byHover: false)
        let states: [(String, IslandModel, JevUsageMonitor, IslandPresentation, DashboardPage, CGFloat, UsageRange)] = [
            ("idle", model, jev, .collapsed, .usage, 0, .today),
            ("idle-hover", model, jev, .emphasized, .usage, 0, .today),
            ("open-top", model, jev, open, .usage, 0, .today),
            ("usage-today", model, jev, open, .usage, 236, .today),
            ("usage-7d", model, jev, open, .usage, 236, .week),
            ("usage-30d", model, jev, open, .usage, 236, .month),
            ("open-no-key", keyless, jev, open, .usage, 0, .today),
            ("jev-today", model, jev, open, .jev, 0, .today),
            ("jev-7d", model, jev, open, .jev, 0, .week),
            ("jev-30d", model, jev, open, .jev, 0, .month),
            ("jev-no-log", model, noJev, open, .jev, 0, .today),
        ]
        for (name, model, jev, presentation, page, offset, range) in states {
            let ui = IslandUIState()
            ui.notchSize = notch
            ui.presentation = presentation
            ui.page = page
            ui.usageRange = range
            ui.jevRange = range
            ui.isSnapshot = true
            ui.snapshotOffset = offset
            let expanded = ui.isExpanded
            let view = IslandView(model: model, jev: jev, ui: ui, onTap: {}, openSettings: {}, quit: {})
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
        try write(PopoverDashboard(model: model, jev: jev, state: PopoverUIState(), snapshotOffset: 0, openSettings: {}),
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
