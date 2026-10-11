import Foundation
import CoreGraphics

/// Stable display identities, independent of AppKit and display enumeration order.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hasNotch: Bool
    public var isBuiltin: Bool

    public init(id: UUID, name: String, hasNotch: Bool, isBuiltin: Bool) {
        self.id = id
        self.name = name
        self.hasNotch = hasNotch
        self.isBuiltin = isBuiltin
    }
}

public enum DisplayPreference: Hashable, Sendable {
    case followMouse
    case automatic
    case allDisplays
    case display(id: UUID, name: String)

    public init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: "islandDisplayID"), let id = UUID(uuidString: raw) {
            self = .display(id: id, name: defaults.string(forKey: "islandDisplayName") ?? "Display")
        } else {
            switch defaults.string(forKey: "islandDisplayMode") {
            case "automatic": self = .automatic
            case "allDisplays": self = .allDisplays
            default: self = .followMouse
            }
        }
    }

    public func save(to defaults: UserDefaults) {
        switch self {
        case .followMouse, .automatic, .allDisplays:
            let mode = self == .automatic ? "automatic" : self == .allDisplays ? "allDisplays" : "followMouse"
            defaults.set(mode, forKey: "islandDisplayMode")
            defaults.removeObject(forKey: "islandDisplayID")
            defaults.removeObject(forKey: "islandDisplayName")
        case .display(let id, let name):
            defaults.set("fixed", forKey: "islandDisplayMode")
            defaults.set(id.uuidString, forKey: "islandDisplayID")
            defaults.set(name, forKey: "islandDisplayName")
        }
    }
}

public enum DisplayTarget: Hashable, Sendable {
    case island(id: UUID, notched: Bool)
    case menuBar

    public var displayID: UUID? {
        if case .island(let id, _) = self { return id }
        return nil
    }

    /// A missing fixed choice follows the mouse without erasing the saved UUID.
    /// All displays has no single target; it resolves like Follow mouse for single-target callers.
    public static func resolve(
        _ preference: DisplayPreference, displays: [DisplayInfo], pointerDisplayID: UUID? = nil,
        forceMenuBar: Bool = false
    ) -> Self {
        guard !forceMenuBar else { return .menuBar }
        if case .display(let id, _) = preference, let display = displays.first(where: { $0.id == id }) {
            return .island(id: id, notched: display.hasNotch)
        }
        if preference == .automatic {
            return displays.first(where: \.hasNotch).map { .island(id: $0.id, notched: true) } ?? .menuBar
        }
        let display = displays.first { $0.id == pointerDisplayID } ?? displays.first
        return display.map { .island(id: $0.id, notched: $0.hasNotch) } ?? .menuBar
    }

    /// Displays that each get an island, or nil for the single-island path
    /// (another mode, `--menubar`, or no displays).
    public static func allDisplayIDs(_ preference: DisplayPreference, displays: [DisplayInfo],
                                     forceMenuBar: Bool = false) -> [UUID]? {
        guard preference == .allDisplays, !forceMenuBar, !displays.isEmpty else { return nil }
        return DisplayDiff(current: [], available: displays.map(\.id)).added
    }
}

/// All displays mode: which per-display islands to create, tear down or re-place.
public struct DisplayDiff: Equatable, Sendable {
    public var added: [UUID]
    public var removed: Set<UUID>
    public var kept: [UUID]

    public init(current: Set<UUID>, available: [UUID]) {
        var seen = Set<UUID>()
        let unique = available.filter { seen.insert($0).inserted }
        added = unique.filter { !current.contains($0) }
        kept = unique.filter(current.contains)
        removed = current.subtracting(unique)
    }
}

public struct DisplayFrame: Equatable, Sendable {
    public var id: UUID
    public var frame: CGRect
    public init(id: UUID, frame: CGRect) { self.id = id; self.frame = frame }
}

/// Non-notched island metrics, shared by placement, rendering and fixtures.
public struct FloatingIslandLayout: Equatable, Sendable {
    public static let contentWidth: CGFloat = 424
    public static let contentInset: CGFloat = 14
    public static let expandedWidth = contentWidth + 2 * contentInset
    public let menuHeight: CGFloat
    public let idleSize: CGSize
    public let topInset: CGFloat

    public init(menuHeight: CGFloat) {
        let resolvedHeight = menuHeight.isFinite && menuHeight > 0 ? menuHeight : 24
        self.menuHeight = resolvedHeight
        idleSize = CGSize(width: 130, height: min(24, resolvedHeight))
        topInset = max(0, (resolvedHeight - idleSize.height) / 2)
    }
}

public enum DisplayGeometry {
    /// AppKit global coordinates. Half-open edges give shared boundaries one owner.
    public static func containing(_ point: CGPoint, displays: [DisplayFrame], fallback: UUID? = nil) -> UUID? {
        displays.first {
            point.x >= $0.frame.minX && point.x < $0.frame.maxX &&
            point.y >= $0.frame.minY && point.y < $0.frame.maxY
        }?.id ?? displays.first(where: { $0.id == fallback })?.id ?? displays.first?.id
    }

    /// Keep hardware notches flush; center floating idle pills in the menu band,
    /// including the virtual band on secondary displays and auto-hidden menus.
    public static func panelFrame(screen: CGRect, visible: CGRect, notch: CGRect?, menuHeight: CGFloat,
                                  preferredSize: CGSize) -> CGRect {
        let inset = notch == nil ? FloatingIslandLayout(menuHeight: menuHeight).topInset : 0
        let top = screen.maxY - inset
        let bottom = notch == nil ? visible.minY : screen.minY
        let height = min(preferredSize.height, max(1, top - bottom - 40))
        return CGRect(x: ((notch?.midX ?? screen.midX) - preferredSize.width / 2).rounded(),
                      y: top - height, width: preferredSize.width, height: height)
    }

    /// Identical monitor names remain distinguishable without depending on enumeration order.
    public static func labels(displays: [DisplayInfo], frames: [DisplayFrame], mainID: UUID?) -> [UUID: String] {
        let mainX = frames.first(where: { $0.id == mainID })?.frame.midX ?? 0
        var result: [UUID: String] = [:]
        for display in displays {
            var label = display.name + (display.isBuiltin ? " (built-in)" : "")
            let peers = displays.filter { $0.name == display.name && $0.isBuiltin == display.isBuiltin }
            if peers.count > 1 {
                let position: String
                if display.id == mainID { position = "Main" }
                else if let x = frames.first(where: { $0.id == display.id })?.frame.midX, x != mainX {
                    position = x < mainX ? "Left" : "Right"
                } else { position = String(display.id.uuidString.suffix(4)) }
                let sameSide = peers.filter { peer in
                    guard peer.id != mainID, let x = frames.first(where: { $0.id == peer.id })?.frame.midX else { return false }
                    return position == "Left" ? x < mainX : position == "Right" && x > mainX
                }.count
                label += " · " + position + (sameSide > 1 ? " · " + display.id.uuidString.suffix(4) : "")
            }
            result[display.id] = label
        }
        return result
    }
}

/// Debounce maturity and expanded blocking are independent. The owner executes one timer per revision.
public struct DisplayRelocation: Equatable, Sendable {
    public private(set) var current: DisplayTarget
    public private(set) var candidate: DisplayTarget?
    public private(set) var ready = false
    public private(set) var revision = 0
    public static let settleDelay: TimeInterval = 0.3

    public init(current: DisplayTarget) { self.current = current }

    /// Returns a new timer token only when the target changes.
    public mutating func observe(_ target: DisplayTarget) -> Int? {
        if target == current {
            if candidate != nil { invalidate() }
            return nil
        }
        guard candidate != target else { return nil }
        revision += 1
        candidate = target
        ready = false
        return revision
    }

    public mutating func settle(_ token: Int, expanded: Bool) -> DisplayTarget? {
        guard token == revision, candidate != nil else { return nil }
        ready = true
        return applyIfReady(expanded: expanded)
    }

    public mutating func applyIfReady(expanded: Bool) -> DisplayTarget? {
        guard ready, !expanded, let candidate else { return nil }
        current = candidate
        invalidate()
        return current
    }

    public mutating func invalidate() {
        revision += 1
        candidate = nil
        ready = false
    }

    /// Screen removal overrides the expanded gate: there is no usable panel to pin anymore.
    public mutating func recoverIfDisconnected(to target: DisplayTarget, available: Set<UUID>) -> Bool {
        guard let id = current.displayID, !available.contains(id) else { return false }
        reset(to: target)
        return true
    }

    public mutating func reset(to target: DisplayTarget) {
        current = target
        invalidate()
    }
}
