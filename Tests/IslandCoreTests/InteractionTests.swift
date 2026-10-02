import Foundation
import Testing

@testable import IslandCore

private func hoverOpened() -> IslandInteraction {
    var state = IslandInteraction(openOnHover: true)
    _ = state.pointerEntered()
    _ = state.timerFired(.hoverOpen)
    return state
}

@Test func interactionDefaultsAndEmphasis() {
    var state = IslandInteraction()
    #expect(!state.openOnHover)
    #expect(!state.pointerInside)
    #expect(!state.isExpanded)
    #expect(state.presentation == .collapsed)
    #expect(state.pointerEntered().isEmpty)
    #expect(state.pointerInside)
    #expect(state.presentation == .emphasized)
    #expect(state.pointerEntered().isEmpty)
    #expect(state.pointerExited() == [.cancel(.hoverOpen)])
    #expect(state.presentation == .collapsed)
    #expect(!state.pointerInside)
    #expect(state.pointerExited().isEmpty)
}

@Test func hoverOpenAndExitTimers() {
    var state = IslandInteraction(openOnHover: true)
    #expect(state.pointerEntered() == [.schedule(.hoverOpen, after: 0.25)])
    #expect(state.timerFired(.hoverOpen) == [.haptic])
    #expect(state.presentation == .expanded(byHover: true))
    #expect(state.isExpanded)
    #expect(state.timerFired(.hoverOpen).isEmpty)
    #expect(state.timerFired(.exitClose).isEmpty)
    #expect(state.isExpanded)
    #expect(state.pointerExited() == [.schedule(.exitClose, after: 0.18)])
    #expect(state.timerFired(.exitClose).isEmpty)
    #expect(state.presentation == .collapsed)
}

@Test func hoverOpenTimerIsIgnoredAfterExit() {
    var state = IslandInteraction(openOnHover: true)
    _ = state.pointerEntered()
    #expect(state.pointerExited() == [.cancel(.hoverOpen)])
    #expect(state.timerFired(.hoverOpen).isEmpty)
    #expect(state.presentation == .collapsed)
}

@Test func reenteringHoverIslandCancelsClosing() {
    var state = hoverOpened()
    _ = state.pointerExited()
    #expect(state.pointerEntered() == [.cancel(.exitClose)])
    #expect(state.timerFired(.exitClose).isEmpty)
    #expect(state.presentation == .expanded(byHover: true))
}

@Test(arguments: [false, true])
func clickingClosedIslandPinsAndTakesFocus(_ emphasized: Bool) {
    var state = IslandInteraction(openOnHover: true)
    if emphasized { _ = state.pointerEntered() }
    #expect(state.clicked() == [.haptic, .takeFocus, .cancel(.hoverOpen)])
    #expect(state.presentation == .expanded(byHover: false))
    #expect(state.clicked().isEmpty)
    #expect(state.timerFired(.hoverOpen).isEmpty)
    #expect(state.timerFired(.exitClose).isEmpty)
    #expect(state.pointerExited().isEmpty)
    #expect(state.isExpanded)
}

@Test func clickingHoverIslandPinsWithoutAnotherHaptic() {
    var state = hoverOpened()
    #expect(state.clicked() == [.takeFocus, .cancel(.exitClose)])
    #expect(state.presentation == .expanded(byHover: false))
    #expect(state.pointerExited().isEmpty)
    #expect(state.timerFired(.exitClose).isEmpty)
    #expect(state.isExpanded)
}

@Test(arguments: [0, 1])
func closingInsideSuppressesHoverUntilPointerLeaves(_ closingMethod: Int) {
    var state = hoverOpened()
    let effects: [IslandEffect]
    switch closingMethod {
    case 0: effects = state.dismiss()
    default: effects = state.gesture(.close)
    }
    #expect(effects == [.cancel(.hoverOpen), .cancel(.exitClose)])
    #expect(state.presentation == .collapsed)
    #expect(state.pointerInside)
    #expect(state.pointerEntered().isEmpty)
    #expect(state.timerFired(.hoverOpen).isEmpty)
    #expect(state.presentation == .collapsed)
    #expect(state.pointerExited().isEmpty)
    #expect(state.pointerEntered() == [.schedule(.hoverOpen, after: 0.25)])
    #expect(state.presentation == .emphasized)
    #expect(state.timerFired(.hoverOpen) == [.haptic])
}

@Test func clickThenDismissOutsideWithoutSuppression() {
    var state = IslandInteraction(openOnHover: true)
    #expect(state.clicked() == [.haptic, .takeFocus, .cancel(.hoverOpen)])
    #expect(state.dismiss() == [.cancel(.hoverOpen), .cancel(.exitClose)])
    #expect(state.pointerEntered() == [.schedule(.hoverOpen, after: 0.25)])
    #expect(state.presentation == .emphasized)
}

@Test func dismissingClosedOrEmphasizedIslandIsNoOp() {
    var state = IslandInteraction()
    #expect(state.dismiss().isEmpty)
    _ = state.pointerEntered()
    #expect(state.dismiss().isEmpty)
    #expect(state.presentation == .emphasized)
}

@Test func otherApplicationActivationClosesPinnedButNotInsideHoverIsland() {
    var state = hoverOpened()
    #expect(state.otherAppActivated().isEmpty)
    #expect(state.presentation == .expanded(byHover: true))
    _ = state.clicked()
    #expect(state.otherAppActivated() == [.cancel(.hoverOpen), .cancel(.exitClose)])
    #expect(state.presentation == .collapsed)
    #expect(state.timerFired(.hoverOpen).isEmpty)
    var outside = hoverOpened()
    _ = outside.pointerExited()
    #expect(outside.otherAppActivated() == [.cancel(.hoverOpen), .cancel(.exitClose)])
    #expect(!outside.isExpanded)
    #expect(outside.otherAppActivated().isEmpty)
}

@Test func gesturesOpenWithFocusAndClose() {
    var state = IslandInteraction()
    #expect(state.gesture(.close).isEmpty)
    #expect(state.gesture(.open) == [.haptic, .takeFocus])
    #expect(state.presentation == .expanded(byHover: false))
    #expect(state.gesture(.open).isEmpty)
    #expect(state.isExpanded)
    #expect(state.gesture(.close) == [.cancel(.hoverOpen), .cancel(.exitClose)])
    #expect(!state.isExpanded)
}

@Test func explicitClickCanReopenSuppressedIsland() {
    var state = hoverOpened()
    _ = state.dismiss()
    #expect(state.clicked() == [.haptic, .takeFocus, .cancel(.hoverOpen)])
    #expect(state.presentation == .expanded(byHover: false))
}

extension ScrollGestureRecognizer {
    fileprivate mutating func sample(
        pull: Double = 0, sideways: Double = 0, time: TimeInterval = 0,
        phase: ScrollPhase = .changed, precise: Bool = true,
        expanded: Bool = false, verticalAllowed: Bool = true
    ) -> ScrollGestureAction? {
        feed(
            pull: pull, sideways: sideways, time: time, phase: phase,
            expanded: expanded, verticalAllowed: verticalAllowed)
    }
}

@Test func strokeVerticalDistanceAndPresentationRules() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 29, phase: .began) == nil)
    #expect(recognizer.sample(pull: 1) == .open)
    #expect(recognizer.sample(pull: -60, expanded: true) == nil)
    #expect(recognizer.sample(pull: -30, phase: .began, expanded: true) == .close)
    #expect(recognizer.sample(pull: 30, phase: .began, expanded: true) == nil)
    #expect(recognizer.sample(pull: -60, expanded: true) == .close)
    #expect(recognizer.sample(pull: -30, phase: .began) == nil)
    #expect(recognizer.sample(pull: 60) == .open)
}

@Test func verticalThresholdUsesWholeVectorLength() {
    var recognizer = ScrollGestureRecognizer()
    #expect(
        recognizer.sample(pull: 29, sideways: 29 * tan(20 * Double.pi / 180), phase: .began) == .open)
}

@Test(arguments: [-30.0, 0, 30])
func verticalConeIncludesItsBoundary(_ degrees: Double) {
    let angle = degrees * Double.pi / 180
    var recognizer = ScrollGestureRecognizer()
    #expect(
        recognizer.sample(pull: 40 * cos(angle), sideways: 40 * sin(angle), phase: .began) == .open)
    #expect(
        recognizer.sample(
            pull: -40 * cos(angle), sideways: 40 * sin(angle), phase: .began, expanded: true) == .close
    )
}

@Test(arguments: [30.01, 45.0, 59.99, 60, 75])
func strokesOutsideVerticalConeNeverFire(_ degrees: Double) {
    let angle = degrees * Double.pi / 180
    for horizontalSign in [-1.0, 1] {
        for verticalSign in [-1.0, 1] {
            var recognizer = ScrollGestureRecognizer()
            #expect(
                recognizer.sample(
                    pull: verticalSign * 100 * cos(angle), sideways: horizontalSign * 100 * sin(angle),
                    phase: .began, expanded: verticalSign < 0) == nil)
        }
    }
}

@Test(arguments: [-1.0, 1], [false, true])
func purelyHorizontalStrokeNeverFires(_ direction: Double, _ precise: Bool) {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(sideways: direction * 100, phase: .began, precise: precise) == nil)
    #expect(recognizer.sample(sideways: direction * 100, precise: precise) == nil)
}

@Test func strokeDirectionRemainsChangeableBeforeConsumption() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(sideways: 5, phase: .began) == nil)
    #expect(recognizer.sample(pull: 30, sideways: -5) == .open)
    #expect(recognizer.sample(pull: 30, sideways: 30, phase: .began) == nil)
    #expect(recognizer.sample(sideways: -30) == .open)
}

@Test(arguments: [ScrollPhase.began, .none])
func verticalPermissionIsSampledForTheWholeStroke(_ firstPhase: ScrollPhase) {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 10, phase: firstPhase, verticalAllowed: false) == nil)
    let continuation: ScrollPhase = firstPhase == .none ? .none : .changed
    #expect(
        recognizer.sample(pull: 20, time: 0.1, phase: continuation, verticalAllowed: true) == nil)
    #expect(
        recognizer.sample(
            pull: -30, sideways: 50, time: 0.2, phase: continuation, verticalAllowed: false)
            == nil)
    #expect(recognizer.sample(pull: 10, time: 1, phase: firstPhase, verticalAllowed: true) == nil)
    #expect(
        recognizer.sample(pull: 20, time: 1.1, phase: continuation, verticalAllowed: false) == .open
    )
}

@Test func idleGapStartsANewWheelStrokeAfterPointThreeSeconds() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 30, time: 0, phase: .none, precise: false) == .open)
    #expect(recognizer.sample(pull: 30, time: 0.3, phase: .none, precise: false) == nil)
    #expect(recognizer.sample(pull: 30, time: 0.601, phase: .none, precise: false) == .open)
    #expect(recognizer.sample(pull: 30, time: 0.602, phase: .none, precise: false) == nil)
}

@Test func aWheelGapResamplesVerticalPermission() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 30, time: 0, phase: .none, verticalAllowed: false) == nil)
    #expect(recognizer.sample(pull: 30, time: 0.1, phase: .none, verticalAllowed: true) == nil)
    #expect(recognizer.sample(pull: 30, time: 0.401, phase: .none, verticalAllowed: true) == .open)
}

@Test func backwardTimeDoesNotCreateAnExtraWheelStroke() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 30, time: 1, phase: .none) == .open)
    #expect(recognizer.sample(pull: 30, time: 0.9, phase: .none) == nil)
}

@Test func impreciseInputCanOpenVertically() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(sideways: 50, phase: .began, precise: false) == nil)
    #expect(recognizer.sample(pull: 30, sideways: -50, precise: false) == .open)
}

@Test func consumptionPreventsSecondActionUntilTheNextStroke() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 30, phase: .began) == .open)
    #expect(recognizer.sample(sideways: 100, expanded: true) == nil)
    #expect(recognizer.sample(pull: -60, expanded: true) == nil)
    #expect(recognizer.sample(pull: -30, phase: .began, expanded: true) == .close)
}

@Test(arguments: [ScrollPhase.ended, .momentum])
func strokeEndingPhasesDiscardMovementWithoutFiring(_ phase: ScrollPhase) {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.sample(pull: 10, phase: .began) == nil)
    #expect(recognizer.sample(pull: 100, phase: phase) == nil)
    #expect(recognizer.sample(pull: 30) == nil)
    #expect(recognizer.sample(pull: 30, phase: .began) == .open)
}

@Test(arguments: [Double.nan, .infinity, -.infinity])
func invalidDeltasAreDroppedWithoutLosingStrokeState(_ invalid: Double) {
    for field in 0..<2 {
        var recognizer = ScrollGestureRecognizer()
        #expect(recognizer.sample(pull: 10, phase: .began) == nil)
        #expect(
            recognizer.sample(pull: field == 0 ? invalid : 0, sideways: field == 1 ? invalid : 0)
                == nil)
        #expect(recognizer.sample(pull: 20) == .open)
        #expect(recognizer.sample(pull: invalid) == nil)
        #expect(recognizer.sample(pull: 30) == nil)
    }
}

@Test func overflowingVectorUpdatesAreDroppedWithoutResetting() {
    var recognizer = ScrollGestureRecognizer()
    let large = Double.greatestFiniteMagnitude
    #expect(recognizer.sample(pull: large, sideways: large, phase: .began) == nil)
    #expect(recognizer.sample(pull: large, sideways: large) == nil)
    #expect(recognizer.sample(pull: -large, sideways: -large) == nil)
    #expect(recognizer.sample(pull: 30) == .open)
}

@Test func elapsedQuotaFractionClampsAndHandlesUnknownOrInvalidPeriods() {
    let now = Fixtures.referenceNow
    var window = QuotaWindow(
        id: "test", label: "Test", usedFraction: 0.9,
        resetsAt: now.addingTimeInterval(90), periodSeconds: 100)
    #expect(abs((window.elapsedFraction(now: now) ?? 0) - 0.1) < 0.000000001)
    window.resetsAt = now.addingTimeInterval(50)
    #expect(window.elapsedFraction(now: now) == 0.5)
    window.resetsAt = now.addingTimeInterval(101)
    #expect(window.elapsedFraction(now: now) == 0)
    window.resetsAt = now.addingTimeInterval(-1)
    #expect(window.elapsedFraction(now: now) == 1)
    window.resetsAt = now
    #expect(window.elapsedFraction(now: now) == 1)
    for period in [Double(0), -1, .nan, .infinity] {
        window.periodSeconds = period
        #expect(window.elapsedFraction(now: now) == nil)
    }
    window.periodSeconds = nil
    #expect(window.elapsedFraction(now: now) == nil)
    window.periodSeconds = 100
    window.resetsAt = nil
    #expect(window.elapsedFraction(now: now) == nil)
    let compatible = QuotaWindow(id: "old", label: "Old", usedFraction: nil, resetsAt: now)
    #expect(compatible.periodSeconds == nil)
}

@Test func quotaParsersPopulatePeriodsForEveryWindow() throws {
    let now = Fixtures.referenceNow
    let files = try JSONDecoder().decode(AuthFilesResponse.self, from: Fixtures.data("auth-files"))
    let claude = HeaderQuotaParser.windows(
        provider: .claude, signals: files.files[0].quota!.signals, observedAt: now)
    #expect(claude.map(\.periodSeconds) == [18000, 604800])
    let codex = HeaderQuotaParser.windows(
        provider: .codex, signals: files.files[2].quota!.signals, observedAt: now)
    #expect(codex.map(\.periodSeconds) == [18000, 604800])
    let claudeResponse = try JSONDecoder().decode(
        APICallResponse.self, from: Fixtures.data("api-call-claude-usage"))
    let liveClaude = LiveQuotaFetcher.parse(provider: .claude, response: claudeResponse, now: now)
    #expect(liveClaude?.windows.map(\.periodSeconds) == [18000, 604800, 604800])
    let codexResponse = try JSONDecoder().decode(
        APICallResponse.self, from: Fixtures.data("api-call-codex-usage"))
    let liveCodex = LiveQuotaFetcher.parse(provider: .codex, response: codexResponse, now: now)
    #expect(liveCodex?.windows.map(\.periodSeconds) == [18000, 604800])
    let unknown = HeaderQuotaParser.windows(
        provider: .codex, signals: ["x-codex-primary-used-percent": "20"], observedAt: now)
    #expect(unknown.first?.periodSeconds == nil)
}
