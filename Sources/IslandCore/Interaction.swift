import Foundation

public enum IslandPresentation: Equatable, Sendable {
    case collapsed
    case emphasized
    case expanded(byHover: Bool)
}

public enum IslandTimer: Equatable, Sendable {
    case hoverOpen
    case exitClose
}

public enum IslandEffect: Equatable, Sendable {
    case schedule(IslandTimer, after: TimeInterval)
    case cancel(IslandTimer)
    case haptic
    case takeFocus
}

/// Pure presentation policy. The controller owns timer execution, focus, and feedback.
public struct IslandInteraction: Equatable, Sendable {
    public static let hoverOpenDelay: TimeInterval = 0.25
    public static let hoverExitDelay: TimeInterval = 0.18

    public var openOnHover: Bool
    public private(set) var presentation: IslandPresentation = .collapsed
    public private(set) var pointerInside = false
    private var suppressed = false

    public init(openOnHover: Bool = false) {
        self.openOnHover = openOnHover
    }

    public var isExpanded: Bool {
        if case .expanded = presentation { return true }
        return false
    }

    public mutating func pointerEntered() -> [IslandEffect] {
        guard !pointerInside else { return [] }
        pointerInside = true
        if presentation == .expanded(byHover: true) { return [.cancel(.exitClose)] }
        guard !suppressed, !isExpanded else { return [] }
        if presentation == .collapsed { presentation = .emphasized }
        return openOnHover ? [.schedule(.hoverOpen, after: Self.hoverOpenDelay)] : []
    }

    public mutating func pointerExited() -> [IslandEffect] {
        guard pointerInside else { return [] }
        pointerInside = false
        suppressed = false
        switch presentation {
        case .emphasized:
            presentation = .collapsed
            return [.cancel(.hoverOpen)]
        case .expanded(byHover: true):
            return [.schedule(.exitClose, after: Self.hoverExitDelay)]
        default:
            return []
        }
    }

    public mutating func timerFired(_ timer: IslandTimer) -> [IslandEffect] {
        switch timer {
        case .hoverOpen:
            guard pointerInside, !suppressed, !isExpanded else { return [] }
            presentation = .expanded(byHover: true)
            return [.haptic]
        case .exitClose:
            guard !pointerInside, presentation == .expanded(byHover: true) else { return [] }
            presentation = .collapsed
            return []
        }
    }

    public mutating func clicked() -> [IslandEffect] {
        switch presentation {
        case .collapsed, .emphasized:
            suppressed = false
            presentation = .expanded(byHover: false)
            return [.haptic, .takeFocus, .cancel(.hoverOpen)]
        case .expanded(byHover: true):
            presentation = .expanded(byHover: false)
            return [.takeFocus, .cancel(.exitClose)]
        case .expanded(byHover: false):
            return []
        }
    }

    public mutating func toggle() -> [IslandEffect] {
        isExpanded ? close() : clicked()
    }

    public mutating func dismiss() -> [IslandEffect] {
        isExpanded ? close() : []
    }

    public mutating func otherAppActivated() -> [IslandEffect] {
        guard isExpanded else { return [] }
        if presentation == .expanded(byHover: true), pointerInside { return [] }
        return close()
    }

    public mutating func gesture(_ action: ScrollGestureAction) -> [IslandEffect] {
        switch action {
        case .open:
            guard !isExpanded else { return [] }
            suppressed = false
            presentation = .expanded(byHover: false)
            return [.haptic]
        case .close:
            return isExpanded ? close() : []
        case .next, .previous:
            return []
        }
    }

    private mutating func close() -> [IslandEffect] {
        presentation = .collapsed
        suppressed = pointerInside
        return [.cancel(.hoverOpen), .cancel(.exitClose)]
    }
}

public enum ScrollGestureAction: Equatable, Sendable {
    case open
    case close
    case next
    case previous
}

public enum ScrollPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case none
    case momentum
}

/// Direction-normalized deltas are accumulated once per physical gesture.
public struct ScrollGestureRecognizer: Equatable, Sendable {
    private enum Axis: Equatable, Sendable { case horizontal, vertical }
    private enum Kind: Equatable, Sendable { case phased, wheel }

    private var kind: Kind?
    private var axis: Axis?
    private var pullTotal = 0.0
    private var swipeTotal = 0.0
    private var previousTime: TimeInterval?
    private var verticalAllowedAtStart = false
    private var fired = false

    public init() {}

    /// Positive pull opens; positive swipe moves to the previous tab.
    /// The caller normalizes direction and scales non-precise wheel deltas by 10.
    public mutating func feed(
        pull: Double, swipe: Double, time: TimeInterval, phase: ScrollPhase,
        precise: Bool, expanded: Bool, verticalAllowed: Bool
    ) -> ScrollGestureAction? {
        guard pull.isFinite, swipe.isFinite, time.isFinite else {
            self = Self()
            return nil
        }
        switch phase {
        case .ended, .momentum:
            self = Self()
            return nil
        case .began:
            begin(.phased, verticalAllowed: verticalAllowed)
        case .changed:
            if kind != .phased { begin(.phased, verticalAllowed: verticalAllowed) }
        case .none:
            let elapsed = previousTime.map { time - $0 } ?? .infinity
            if kind != .wheel || elapsed > 0.35 || elapsed < 0 {
                begin(.wheel, verticalAllowed: verticalAllowed)
            }
        }
        previousTime = time
        guard !fired else { return nil }

        switch axis {
        case .horizontal:
            swipeTotal += swipe
        case .vertical:
            pullTotal += pull
        case nil:
            pullTotal += pull
            swipeTotal += swipe
        }
        guard pullTotal.isFinite, swipeTotal.isFinite else {
            self = Self()
            return nil
        }

        if axis == nil {
            let verticalEnabled = kind == .phased ? verticalAllowedAtStart : verticalAllowed
            if precise, abs(swipeTotal) >= 4, abs(swipeTotal) >= 1.5 * abs(pullTotal) {
                axis = .horizontal
            } else if verticalEnabled, abs(pullTotal) >= 4,
                abs(pullTotal) >= 1.5 * abs(swipeTotal)
            {
                axis = .vertical
            }
        }

        let action: ScrollGestureAction?
        switch axis {
        case .horizontal where abs(swipeTotal) >= 40:
            action = swipeTotal < 0 ? .next : .previous
        case .vertical where abs(pullTotal) >= 24:
            if pullTotal > 0, !expanded {
                action = .open
            } else if pullTotal < 0, expanded {
                action = .close
            } else {
                action = nil
            }
        default:
            action = nil
        }
        if action != nil { fired = true }
        return action
    }

    private mutating func begin(_ kind: Kind, verticalAllowed: Bool) {
        self = Self()
        self.kind = kind
        verticalAllowedAtStart = verticalAllowed
    }
}
