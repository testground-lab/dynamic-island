import Foundation
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
    #expect(DisplayTarget.resolve(preference, displays: [external, internalDisplay], forceMenuBar: true) == .menuBar)
    #expect(DisplayTarget.resolve(.display(id: internalDisplay.id, name: internalDisplay.name), displays: [internalDisplay]) == .island(id: internalDisplay.id, notched: true))
}

@Test func displayPreferencesPersistAndDoNotForgetDisconnectedDisplay() throws {
    let suite = "display-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DisplayPreference(defaults: defaults) == .automatic)
    for value in ["", "invalid"] {
        defaults.set(value, forKey: "islandDisplayID")
        #expect(DisplayPreference(defaults: defaults) == .automatic)
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
}
