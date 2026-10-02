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

        // Page cap as on a 1169 pt tall built-in display (60% of its visible height).
        let maxContent: CGFloat = 680
        let states: [(String, IslandPresentation, CGFloat, UsageRange)] = [
            ("idle", .collapsed, 0, .today),
            ("idle-hover", .emphasized, 0, .today),
            ("open-top", .expanded(byHover: false), 0, .today),
            ("open-scrolled-usage", .expanded(byHover: false), 236, .week),
        ]
        for (name, presentation, offset, range) in states {
            let ui = IslandUIState()
            ui.notchSize = notch
            ui.presentation = presentation
            ui.usageRange = range
            ui.isSnapshot = true
            ui.maxContentHeight = maxContent
            ui.panelHeight = notch.height + ui.maxContentHeight + 80
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
        try write(PopoverDashboard(model: model, layout: PopoverLayout(), snapshotOffset: 0, openSettings: {}, range: .today),
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
