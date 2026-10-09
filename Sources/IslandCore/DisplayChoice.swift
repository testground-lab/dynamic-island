import Foundation

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
    case automatic
    case display(id: UUID, name: String)

    public init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: "islandDisplayID"), let id = UUID(uuidString: raw) {
            self = .display(id: id, name: defaults.string(forKey: "islandDisplayName") ?? "Display")
        } else {
            self = .automatic
        }
    }

    public func save(to defaults: UserDefaults) {
        switch self {
        case .automatic:
            defaults.removeObject(forKey: "islandDisplayID")
            defaults.removeObject(forKey: "islandDisplayName")
        case .display(let id, let name):
            defaults.set(id.uuidString, forKey: "islandDisplayID")
            defaults.set(name, forKey: "islandDisplayName")
        }
    }
}

public enum DisplayTarget: Hashable, Sendable {
    case island(id: UUID, notched: Bool)
    case menuBar

    /// A missing explicit choice falls back without changing the saved preference.
    public static func resolve(
        _ preference: DisplayPreference, displays: [DisplayInfo], forceMenuBar: Bool = false
    ) -> Self {
        guard !forceMenuBar else { return .menuBar }
        if case .display(let id, _) = preference, let display = displays.first(where: { $0.id == id }) {
            return .island(id: id, notched: display.hasNotch)
        }
        if let display = displays.first(where: \.hasNotch) {
            return .island(id: display.id, notched: true)
        }
        return .menuBar
    }
}
