import Foundation
import CoreGraphics
import Testing
@testable import IslandCore

@Test func displayTargetsRespectExplicitChoiceAndAutomaticFallback() {
    let internalDisplay = DisplayInfo(id: UUID(), name: "Built-in", hasNotch: true, isBuiltin: true)
    let external = DisplayInfo(id: UUID(), name: "Studio", hasNotch: false, isBuiltin: false)
    let preference = DisplayPreference.display(id: external.id, name: external.name)
    #expect(DisplayTarget.resolve(.automatic, displays: [external, internalDisplay]) == .island(id: internalDisplay.id, notched: true))
    #expect(DisplayTarget.resolve(.automatic, displays: [external]) == .menuBar)
    #expect(DisplayTarget.resolve(.automatic, displays: []) == .menuBar)
    #expect(DisplayTarget.resolve(preference, displays: [internalDisplay, external]) == .island(id: external.id, notched: false))
    #expect(DisplayTarget.resolve(preference, displays: [internalDisplay]) == .island(id: internalDisplay.id, notched: true))
    #expect(DisplayTarget.resolve(preference, displays: []) == .menuBar)
    #expect(DisplayTarget.resolve(preference, displays: [external]) == .island(id: external.id, notched: false))
    for mode in [DisplayPreference.followMouse, .automatic, .allDisplays, preference] {
        #expect(DisplayTarget.resolve(mode, displays: [external, internalDisplay], pointerDisplayID: external.id, forceMenuBar: true) == .menuBar)
    }
    #expect(DisplayTarget.resolve(.followMouse, displays: [internalDisplay, external], pointerDisplayID: external.id) == .island(id: external.id, notched: false))
    #expect(DisplayTarget.resolve(.display(id: UUID(), name: "Missing"), displays: [internalDisplay, external], pointerDisplayID: external.id) == .island(id: external.id, notched: false))
    #expect(DisplayTarget.resolve(.followMouse, displays: [external], pointerDisplayID: UUID()) == .island(id: external.id, notched: false))
    #expect(DisplayTarget.resolve(.followMouse, displays: []) == .menuBar)
    #expect(DisplayTarget.resolve(.allDisplays, displays: []) == .menuBar)
}

@Test func allDisplaysDiffKeepsPlacesAndRemovesByStableID() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let diff = DisplayDiff(current: [a, b], available: [c, b])
    #expect(diff.added == [c])
    #expect(diff.kept == [b])
    #expect(diff.removed == [a])
    #expect(DisplayDiff(current: [], available: [a, b]).added == [a, b])
    #expect(DisplayDiff(current: [a, b], available: []).removed == [a, b])
    let same = DisplayDiff(current: [a, b], available: [b, a])
    #expect(same.added.isEmpty && same.removed.isEmpty && same.kept == [b, a])
    #expect(DisplayDiff(current: [], available: [a, a]).added == [a])
    #expect(DisplayDiff(current: [a], available: [a, a]).kept == [a])
}

@Test func allDisplaysModeNeedsDisplaysAndYieldsToMenuBarFlag() {
    let builtin = DisplayInfo(id: UUID(), name: "Built-in", hasNotch: true, isBuiltin: true)
    let external = DisplayInfo(id: UUID(), name: "Studio", hasNotch: false, isBuiltin: false)
    #expect(DisplayTarget.allDisplayIDs(.allDisplays, displays: [external, builtin]) == [external.id, builtin.id])
    #expect(DisplayTarget.allDisplayIDs(.allDisplays, displays: [external, external, builtin]) == [external.id, builtin.id])
    #expect(DisplayTarget.allDisplayIDs(.allDisplays, displays: [external], forceMenuBar: true) == nil)
    #expect(DisplayTarget.allDisplayIDs(.allDisplays, displays: []) == nil)
    for mode in [DisplayPreference.followMouse, .automatic, .display(id: external.id, name: external.name)] {
        #expect(DisplayTarget.allDisplayIDs(mode, displays: [external, builtin]) == nil)
    }
}

@Test func displayPreferencesPersistAndDoNotForgetDisconnectedDisplay() throws {
    let suite = "display-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DisplayPreference(defaults: defaults) == .followMouse)
    for value in ["", "invalid"] {
        defaults.set(value, forKey: "islandDisplayID")
        #expect(DisplayPreference(defaults: defaults) == .followMouse)
    }
    let preference = DisplayPreference.display(id: UUID(), name: "External display")
    preference.save(to: defaults)
    #expect(DisplayPreference(defaults: defaults) == preference)
    #expect(DisplayTarget.resolve(preference, displays: []) == .menuBar)
    #expect(DisplayPreference(defaults: defaults) == preference)
    DisplayPreference.automatic.save(to: defaults)
    #expect(DisplayPreference(defaults: defaults) == .automatic)
    #expect(defaults.object(forKey: "islandDisplayID") == nil)
    #expect(defaults.object(forKey: "islandDisplayName") == nil)
    preference.save(to: defaults)
    DisplayPreference.allDisplays.save(to: defaults)
    #expect(DisplayPreference(defaults: defaults) == .allDisplays)
    #expect(defaults.string(forKey: "islandDisplayMode") == "allDisplays")
    #expect(defaults.object(forKey: "islandDisplayID") == nil)
    #expect(defaults.object(forKey: "islandDisplayName") == nil)
    DisplayPreference.followMouse.save(to: defaults)
    #expect(DisplayPreference(defaults: defaults) == .followMouse)
}

@Test func pointerUsesGlobalCoordinatesAndHalfOpenSharedEdges() {
    let main = DisplayFrame(id: UUID(), frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let left = DisplayFrame(id: UUID(), frame: CGRect(x: -1800, y: -990, width: 1800, height: 1169))
    let right = DisplayFrame(id: UUID(), frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
    let displays = [main, left, right]
    #expect(DisplayGeometry.containing(CGPoint(x: -100, y: -100), displays: displays) == left.id)
    #expect(DisplayGeometry.containing(CGPoint(x: 0, y: 10), displays: displays) == main.id)
    #expect(DisplayGeometry.containing(CGPoint(x: 1920, y: 100), displays: displays) == right.id)
    #expect(DisplayGeometry.containing(CGPoint(x: 100, y: 1080), displays: displays, fallback: right.id) == right.id)
    #expect(DisplayGeometry.containing(CGPoint(x: 0, y: -2000), displays: displays, fallback: UUID()) == main.id)
    #expect(DisplayGeometry.containing(.zero, displays: []) == nil)
}

@Test func floatingPlacementCentersInMenuBandAcrossMenuPoliciesAndGlobalOrigins() {
    let size = CGSize(width: 544, height: 322)
    // Main, secondary and auto-hidden menus use the same explicit virtual band.
    for origin in [CGPoint.zero, CGPoint(x: 1920, y: 0), CGPoint(x: -1920, y: -990)] {
        let screen = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
        for reservedTop in [0.0, 2.0, 30.0] {
            let visible = CGRect(x: origin.x, y: origin.y + 40, width: 1920,
                                 height: 1040 - reservedTop)
            let frame = DisplayGeometry.panelFrame(screen: screen, visible: visible, notch: nil,
                                                  menuHeight: 30, preferredSize: size)
            #expect(frame.maxY == screen.maxY - 3)
            #expect(frame.maxY - 12 == screen.maxY - 15) // idle center = menu center
            #expect(frame.midX == screen.midX)
            #expect(frame.height == size.height)
        }
    }
    let tiny = CGRect(x: 0, y: 0, width: 800, height: 35)
    #expect(DisplayGeometry.panelFrame(screen: tiny, visible: tiny, notch: nil,
                                      menuHeight: 30, preferredSize: size).height == 1)
    let notch = CGRect(x: 940, y: 1048, width: 40, height: 32)
    let native = DisplayGeometry.panelFrame(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           visible: .zero, notch: notch, menuHeight: 30, preferredSize: size)
    #expect(native.maxY == 1080 && native.midX == notch.midX)
    let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let dock = CGRect(x: 1920, y: 800, width: 1920, height: 280)
    #expect(DisplayGeometry.panelFrame(screen: screen, visible: dock, notch: nil,
                                      menuHeight: 30, preferredSize: size).height == 237)
}

@Test func floatingLayoutAdaptsIdleHeightAndKeepsContentWidth() {
    let cases: [(CGFloat, CGFloat, CGFloat)] = [(30, 24, 3), (28, 24, 2), (22, 22, 0)]
    for (bar, height, inset) in cases {
        let layout = FloatingIslandLayout(menuHeight: bar)
        #expect(layout.menuHeight == bar)
        #expect(layout.idleSize == CGSize(width: 130, height: height))
        #expect(layout.topInset == inset)
        #expect(layout.topInset + layout.idleSize.height / 2 == bar / 2)
        let screen = CGRect(x: -2304, y: -1296, width: 2304, height: 1296)
        let frame = DisplayGeometry.panelFrame(screen: screen, visible: screen, notch: nil,
                                              menuHeight: bar, preferredSize: CGSize(width: 544, height: 322))
        #expect(frame.maxY == screen.maxY - inset)
        #expect(frame.midX == screen.midX)
    }
    #expect(FloatingIslandLayout.contentWidth == 424)
    #expect(FloatingIslandLayout.contentInset == 14)
    #expect(FloatingIslandLayout.expandedWidth == 452)
    #expect(FloatingIslandLayout.expandedWidth - 2 * FloatingIslandLayout.contentInset == FloatingIslandLayout.contentWidth)
}

@Test func invalidMenuHeightFallsBackToFiniteFloatingGeometry() {
    let screen = CGRect(x: -1920, y: -990, width: 1920, height: 1080)
    for bar: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
        let layout = FloatingIslandLayout(menuHeight: bar)
        #expect(layout.menuHeight == 24)
        #expect(layout.idleSize == CGSize(width: 130, height: 24))
        #expect(layout.topInset == 0)
        let frame = DisplayGeometry.panelFrame(screen: screen, visible: screen, notch: nil,
                                              menuHeight: bar, preferredSize: CGSize(width: 544, height: 322))
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
        #expect(frame.width.isFinite && frame.height.isFinite)
        #expect(frame.maxY == screen.maxY)
    }
}

@Test func identicalDisplaysGetStablePositionLabels() {
    let ids = [UUID(), UUID(), UUID()]
    let displays = ids.map { DisplayInfo(id: $0, name: "DELL", hasNotch: false, isBuiltin: false) }
    let frames = ids.enumerated().map { DisplayFrame(id: $0.element, frame: CGRect(x: ($0.offset - 1) * 1920, y: 0, width: 1920, height: 1080)) }
    let labels = DisplayGeometry.labels(displays: displays, frames: frames, mainID: ids[1])
    #expect(labels[ids[0]] == "DELL · Left")
    #expect(labels[ids[1]] == "DELL · Main")
    #expect(labels[ids[2]] == "DELL · Right")
    #expect(DisplayGeometry.labels(displays: displays.reversed(), frames: frames.reversed(), mainID: ids[1]) == labels)
    let vertical = frames.map { DisplayFrame(id: $0.id, frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080)) }
    let verticalLabels = DisplayGeometry.labels(displays: displays, frames: vertical, mainID: ids[1])
    #expect(Set(verticalLabels.values).count == 3)
}

@Test func relocationMaturityIsIndependentOfExpansion() throws {
    let a = DisplayTarget.island(id: UUID(), notched: true)
    let b = DisplayTarget.island(id: UUID(), notched: false)
    var state = DisplayRelocation(current: a)
    let token = try #require({ state.observe(b) }())
    #expect({ state.observe(b) == nil }()) // motion within one screen does not restart debounce
    #expect({ state.applyIfReady(expanded: false) == nil }()) // hover closes at .18s, target not mature yet
    #expect({ state.settle(token, expanded: true) == nil }()) // click pin or --expanded
    #expect(state.ready && state.current == a)
    #expect({ state.applyIfReady(expanded: true) == nil }())
    #expect({ state.applyIfReady(expanded: false) == b }())
    #expect(state.current == b && state.candidate == nil)
}

@Test func relocationRejectsStaleTimersAndReplacementReadiness() throws {
    let a = DisplayTarget.island(id: UUID(), notched: true)
    let b = DisplayTarget.island(id: UUID(), notched: false)
    let c = DisplayTarget.island(id: UUID(), notched: false)
    var state = DisplayRelocation(current: a)
    let bToken = try #require({ state.observe(b) }())
    #expect({ state.settle(bToken, expanded: true) == nil }())
    let cToken = try #require({ state.observe(c) }())
    #expect({ !state.ready && state.applyIfReady(expanded: false) == nil }())
    #expect({ state.settle(bToken, expanded: false) == nil }())
    #expect({ state.settle(cToken, expanded: false) == c }())
    let backToken = try #require({ state.observe(b) }())
    #expect({ state.observe(c) == nil && state.candidate == nil }())
    #expect({ state.settle(backToken, expanded: false) == nil }())
}

@Test func topologyInvalidatesTimersAndRecoversEvenPinnedExpanded() throws {
    let aID = UUID(), bID = UUID()
    let a = DisplayTarget.island(id: aID, notched: true)
    let b = DisplayTarget.island(id: bID, notched: false)
    var state = DisplayRelocation(current: a)
    let token = try #require({ state.observe(b) }())
    state.invalidate() // same UUID resolution change is still a new layout generation
    #expect({ state.settle(token, expanded: false) == nil }())
    let next = try #require({ state.observe(b) }())
    #expect({ state.settle(next, expanded: true) == nil }())
    #expect({ !state.recoverIfDisconnected(to: b, available: [aID, bID]) }())
    // Removal bypasses pin/--expanded; AppDelegate recreates the panel on the surviving screen.
    #expect({ state.recoverIfDisconnected(to: b, available: [bID]) }())
    #expect(state.current == b && state.candidate == nil && !state.ready)
    #expect({ state.settle(next, expanded: false) == nil }())
    #expect({ state.recoverIfDisconnected(to: .menuBar, available: []) }())
    #expect(state.current == .menuBar)
}
