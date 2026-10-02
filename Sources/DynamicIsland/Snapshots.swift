import AppKit
import IslandCore
import SwiftUI

/// `DynamicIsland --snapshot <dir>` renders the demo island (collapsed,
/// expanded, menu-bar label) to PNGs without opening any window. Used for
/// design review; needs no Screen Recording permission.
@MainActor
enum Snapshots {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = IslandModel.demo()
        let notch = CGSize(width: 220, height: 38)

        for expanded in [false, true] {
            let ui = IslandUIState()
            ui.notchSize = notch
            ui.isExpanded = expanded
            ui.isSnapshot = true
            let view = IslandView(model: model, ui: ui, openSettings: {}, quit: {})
                .frame(width: IslandMetrics.panelSize.width, height: expanded ? IslandMetrics.panelSize.height : 80)
                .background(Color(white: 0.82)) // stand-in for a light desktop
            try write(view, to: directory.appendingPathComponent(expanded ? "expanded.png" : "collapsed.png"))
        }
        try write(MenuBarLabel(model: model).padding(6).background(Color(white: 0.9)),
                  to: directory.appendingPathComponent("menubar.png"))
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
