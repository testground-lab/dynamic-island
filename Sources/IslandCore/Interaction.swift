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
            return [.haptic, .takeFocus]
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

/// Interprets a complete movement vector rather than committing to an axis early.
/// A stroke can change direction until it produces an action; afterward it is consumed.
public struct ScrollGestureRecognizer: Equatable, Sendable {
    private struct Stroke: Equatable, Sendable {
        let startedAt: TimeInterval
        let permitsVertical: Bool
        var lastEventAt: TimeInterval
        var dx = 0.0
        var dy = 0.0
        var consumed = false

        init(time: TimeInterval, permitsVertical: Bool) {
            startedAt = time
            lastEventAt = time
            self.permitsVertical = permitsVertical
        }
    }

    private var stroke: Stroke?
    private static let coneHalfAngle = Double.pi / 6
    private static let angleTolerance = 4 * Double.ulpOfOne

    public init() {}

    /// Supply screen-direction deltas: down is positive pull, right is positive swipe.
    /// Phased input starts a stroke explicitly; unphased input separates strokes by idle gaps.
    /// Vertical permission belongs to the stroke's first event, not later pointer movement.
    public mutating func feed(
        pull: Double, swipe: Double, time: TimeInterval, phase: ScrollPhase,
        precise: Bool, expanded: Bool, verticalAllowed: Bool
    ) -> ScrollGestureAction? {
        guard pull.isFinite, swipe.isFinite, time.isFinite else { return nil }

        switch phase {
        case .ended, .momentum:
            stroke = nil
            return nil
        case .began:
            stroke = Stroke(time: time, permitsVertical: verticalAllowed)
        case .none:
            if stroke.map({ time - $0.lastEventAt > 0.3 }) ?? true {
                stroke = Stroke(time: time, permitsVertical: verticalAllowed)
            }
        case .changed:
            break
        }
        guard var movement = stroke else { return nil }
        if movement.consumed {
            movement.lastEventAt = time
            stroke = movement
            return nil
        }

        let dx = movement.dx + swipe
        let dy = movement.dy + pull
        // An unrepresentable displacement is discarded just like an invalid delta.
        guard dx.isFinite, dy.isFinite else { return nil }
        movement.dx = dx
        movement.dy = dy
        movement.lastEventAt = time
        let action = Self.action(for: movement, precise: precise, expanded: expanded)
        movement.consumed = action != nil
        stroke = movement
        return action
    }

    private static func action(
        for movement: Stroke, precise: Bool, expanded: Bool
    ) -> ScrollGestureAction? {
        guard hypot(movement.dx, movement.dy) >= 30 else { return nil }
        let horizontalDistance = abs(movement.dx)
        let verticalDistance = abs(movement.dy)
        let coneBoundary = coneHalfAngle + angleTolerance

        if atan2(horizontalDistance, verticalDistance) <= coneBoundary {
            guard movement.permitsVertical else { return nil }
            if movement.dy > 0, !expanded { return .open }
            if movement.dy < 0, expanded { return .close }
        } else if precise, horizontalDistance >= 50,
            atan2(verticalDistance, horizontalDistance) <= coneBoundary
        {
            return movement.dx < 0 ? .next : .previous
        }
        return nil
    }
}
