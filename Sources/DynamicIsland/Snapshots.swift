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

        let states: [(String, IslandPresentation, IslandTab, UsageRange)] = [
            ("idle", .collapsed, .limits, .today),
            ("idle-hover", .emphasized, .limits, .today),
            ("limits", .expanded(byHover: false), .limits, .today),
            ("usage-today", .expanded(byHover: false), .usage, .today),
            ("usage-7d", .expanded(byHover: false), .usage, .week),
            ("usage-30d", .expanded(byHover: false), .usage, .month),
        ]
        for (name, presentation, tab, range) in states {
            let ui = IslandUIState()
            ui.notchSize = notch
            ui.presentation = presentation
            ui.tab = tab
            ui.usageRange = range
            ui.isSnapshot = true
            let expanded = ui.isExpanded
            let view = IslandView(model: model, ui: ui, onTap: {}, openSettings: {}, quit: {})
                .frame(width: IslandMetrics.panelSize.width, height: expanded ? IslandMetrics.panelSize.height : 60)
                .background(Color(white: 0.82)) // stand-in for a light desktop
            try write(view, to: directory.appendingPathComponent(name + ".png"))
        }
        try write(MenuBarLabel(model: model).padding(6).background(Color(white: 0.15)),
                  to: directory.appendingPathComponent("menubar.png"))
        try write(PopoverDashboard(model: model, scrollable: false, openSettings: {}, tab: .usage, range: .week),
                  to: directory.appendingPathComponent("menubar-popover-usage-7d.png"))
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
