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

@Test(arguments: [0, 1, 2])
func closingInsideSuppressesHoverUntilPointerLeaves(_ closingMethod: Int) {
    var state = hoverOpened()
    let effects: [IslandEffect]
    switch closingMethod {
    case 0: effects = state.toggle()
    case 1: effects = state.dismiss()
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

@Test func toggleCanOpenAndCloseOutsideWithoutSuppression() {
    var state = IslandInteraction(openOnHover: true)
    #expect(state.toggle() == [.haptic, .takeFocus, .cancel(.hoverOpen)])
    #expect(state.toggle() == [.cancel(.hoverOpen), .cancel(.exitClose)])
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

@Test func gesturesOpenWithoutFocusAndIgnoreTabActions() {
    var state = IslandInteraction()
    #expect(state.gesture(.next).isEmpty)
    #expect(state.gesture(.previous).isEmpty)
    #expect(state.gesture(.close).isEmpty)
    #expect(state.gesture(.open) == [.haptic])
    #expect(state.presentation == .expanded(byHover: false))
    #expect(state.gesture(.open).isEmpty)
    #expect(state.gesture(.next).isEmpty)
    #expect(state.gesture(.previous).isEmpty)
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
    fileprivate mutating func event(
        pull: Double = 0, swipe: Double = 0, time: TimeInterval = 0,
        phase: ScrollPhase = .changed, precise: Bool = true, expanded: Bool = false,
        verticalAllowed: Bool = true
    ) -> ScrollGestureAction? {
        feed(
            pull: pull, swipe: swipe, time: time, phase: phase, precise: precise,
            expanded: expanded, verticalAllowed: verticalAllowed)
    }
}

@Test func verticalGesturesAccumulateToThresholdAndRespectPresentation() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 4, phase: .began) == nil)
    #expect(recognizer.event(pull: 19) == nil)
    #expect(recognizer.event(pull: 1) == .open)
    #expect(recognizer.event(pull: -48, expanded: true) == nil)
    #expect(recognizer.event(pull: -24, phase: .began, expanded: true) == .close)
    #expect(recognizer.event(pull: -24, phase: .began) == nil)
    #expect(recognizer.event(pull: 48) == .open)
    #expect(recognizer.event(pull: 24, phase: .began, expanded: true) == nil)
    #expect(recognizer.event(pull: -48, expanded: true) == .close)
}

@Test(arguments: [false, true])
func horizontalGesturesAreDirectionalAndSingleFire(_ expanded: Bool) {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(swipe: -4, phase: .began, expanded: expanded) == nil)
    #expect(recognizer.event(swipe: -35, expanded: expanded) == nil)
    #expect(recognizer.event(swipe: -1, expanded: expanded) == .next)
    #expect(recognizer.event(swipe: 100, expanded: expanded) == nil)
    #expect(recognizer.event(swipe: 40, phase: .began, expanded: expanded) == .previous)
}

@Test func axisChoiceAccumulatesBothDeltasAndLocksAtRatio() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 2, swipe: 2, phase: .began) == nil)
    #expect(recognizer.event(pull: 1, swipe: 2) == nil)
    #expect(recognizer.event(pull: 1, swipe: 2) == nil)
    // Totals 4:6 lock horizontal at exactly 1.5x; later vertical noise is ignored.
    #expect(recognizer.event(pull: 100, swipe: 34) == .previous)
    #expect(recognizer.event(pull: 6, swipe: 4, phase: .began) == nil)
    #expect(recognizer.event(pull: 18, swipe: 100) == .open)
}

@Test func axisDoesNotLockBelowFourOrBeforeDominance() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 3, phase: .began) == nil)
    #expect(recognizer.event(swipe: 40) == .previous)
    #expect(recognizer.event(pull: 5.9, swipe: 4, phase: .began) == nil)
    #expect(recognizer.event(swipe: 36) == .previous)
    #expect(recognizer.event(pull: 4, phase: .began) == nil)
    #expect(recognizer.event(swipe: 100) == nil)
    #expect(recognizer.event(pull: 20) == .open)
}

@Test func phasedVerticalPermissionIsCapturedAtBegan() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 2, phase: .began, verticalAllowed: false) == nil)
    #expect(recognizer.event(pull: 24, verticalAllowed: true) == nil)
    #expect(recognizer.event(pull: 4, phase: .began, verticalAllowed: true) == nil)
    #expect(recognizer.event(pull: 20, verticalAllowed: false) == .open)
}

@Test func wheelPermissionIsNotCapturedAndHorizontalWheelsAreIgnored() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(swipe: 100, phase: .none, precise: false) == nil)
    #expect(
        recognizer.event(pull: 2, time: 1, phase: .none, precise: false, verticalAllowed: false)
            == nil)
    #expect(
        recognizer.event(pull: 22, time: 1.1, phase: .none, precise: false, verticalAllowed: true)
            == .open)
}

@Test func wheelGesturesSplitOnlyAfterGapOrBackwardsTime() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 24, time: 0, phase: .none, precise: false) == .open)
    #expect(recognizer.event(pull: 24, time: 0.35, phase: .none, precise: false) == nil)
    #expect(recognizer.event(pull: 24, time: 0.701, phase: .none, precise: false) == .open)
    #expect(recognizer.event(pull: 24, time: 0.2, phase: .none, precise: false) == .open)
}

@Test(arguments: [ScrollPhase.ended, .momentum])
func endingAndMomentumNeverFireAndResetGesture(_ phase: ScrollPhase) {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.event(pull: 24, phase: .began) == .open)
    #expect(recognizer.event(swipe: 100, phase: phase) == nil)
    #expect(recognizer.event(swipe: 40, phase: .began) == .previous)
}

@Test(arguments: [Double.nan, .infinity, -.infinity])
func nonfiniteInputsResetWithoutFiring(_ invalid: Double) {
    for field in 0..<3 {
        var recognizer = ScrollGestureRecognizer()
        #expect(recognizer.event(pull: 24, phase: .began) == .open)
        #expect(
            recognizer.event(
                pull: field == 0 ? invalid : 0,
                swipe: field == 1 ? invalid : 0,
                time: field == 2 ? invalid : 0) == nil)
        #expect(recognizer.event(swipe: 40) == .previous)
    }
}

@Test func overflowingAccumulationResetsSafely() {
    var recognizer = ScrollGestureRecognizer()
    let large = Double.greatestFiniteMagnitude
    #expect(recognizer.event(pull: large, swipe: large, phase: .began) == nil)
    #expect(recognizer.event(pull: large, swipe: large) == nil)
    #expect(recognizer.event(swipe: 40) == .previous)
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
