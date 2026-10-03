import Foundation
import Testing

@testable import IslandCore

@Test func bothPagesShownByDefault() {
    let pages = DashboardPages(defaults: VolatileDefaults())
    #expect(pages.shown == [.usage, .jev])
    #expect(pages.current == .usage)
    #expect(!pages.isLocked(.usage) && !pages.isLocked(.jev))
}

@Test func shownPagesPersist() {
    let defaults = VolatileDefaults()
    var pages = DashboardPages()
    pages.setEnabled(.jev, false)
    pages.save(to: defaults)
    #expect(defaults.object(forKey: "showUsagePage") as? Bool == true)
    #expect(defaults.object(forKey: "showJevPage") as? Bool == false)
    #expect(DashboardPages(defaults: defaults).shown == [.usage])

    pages.setEnabled(.jev, true)
    pages.setEnabled(.usage, false)
    pages.save(to: defaults)
    let restored = DashboardPages(defaults: defaults)
    #expect(restored.shown == [.jev])
    #expect(restored.current == .jev)
}

@Test func savedStateWithNoPageShowsBoth() {
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "showUsagePage")
    defaults.set(false, forKey: "showJevPage")
    #expect(DashboardPages(defaults: defaults).shown == [.usage, .jev])
    #expect(DashboardPages(enabled: []).shown == [.usage, .jev])
}

@Test func nonBoolSavedValueHidesOnlyThatPage() {
    let defaults = VolatileDefaults()
    defaults.set("garbage", forKey: "showJevPage")
    #expect(DashboardPages(defaults: defaults).shown == [.usage])
    defaults.set(["x"], forKey: "showUsagePage")
    #expect(DashboardPages(defaults: defaults).shown == [.usage, .jev]) // never zero pages
}

@Test func theLastShownPageCantBeHidden() {
    var pages = DashboardPages()
    pages.setEnabled(.jev, false)
    #expect(pages.isLocked(.usage))
    #expect(!pages.isLocked(.jev)) // hidden: turning it on is always allowed
    pages.setEnabled(.usage, false)
    #expect(pages.shown == [.usage])
    #expect(pages.current == .usage)
    pages.setEnabled(.jev, true)
    #expect(pages.shown == [.usage, .jev])
    #expect(!pages.isLocked(.usage))
}

@Test(arguments: DashboardPage.allCases)
func hidingTheOpenPageOpensTheOther(_ open: DashboardPage) {
    var pages = DashboardPages(current: open)
    pages.setEnabled(open, false)
    let other = DashboardPage.allCases.first { $0 != open }
    #expect(pages.current == other)
    #expect(pages.shown == [other])
}

@Test func hidingAnotherPageKeepsTheOpenOne() {
    var pages = DashboardPages(current: .jev)
    pages.setEnabled(.usage, false)
    #expect(pages.current == .jev)
}

/// Applies each action in turn; returns which ones moved and the page reached.
private func swipe(_ pages: DashboardPages, _ actions: [ScrollGestureAction]) -> ([Bool], DashboardPage) {
    var pages = pages
    let moved = actions.map { pages.apply($0) }
    return (moved, pages.current)
}

@Test func swipesStepThroughShownPagesAndStopAtTheEnds() {
    let (moved, end) = swipe(DashboardPages(), [.previousPage, .nextPage, .nextPage, .open, .close])
    #expect(moved == [false, true, false, false, false])
    #expect(end == .jev)
    let (back, start) = swipe(DashboardPages(current: .jev), [.previousPage, .previousPage])
    #expect(back == [true, false])
    #expect(start == .usage)
}

@Test(arguments: DashboardPage.allCases)
func onePageIgnoresSwipesAndDots(_ only: DashboardPage) {
    var pages = DashboardPages(enabled: [only])
    #expect(pages.shown == [only]) // a single dot stays in the header
    let (moved, end) = swipe(pages, [.nextPage, .previousPage])
    #expect(moved == [false, false])
    #expect(end == only)
    for page in DashboardPage.allCases {
        pages.show(page)
        #expect(pages.current == only)
    }
}

@Test func requestedPageFallsBackWhenHidden() {
    // --page jev
    var both = DashboardPages()
    both.show(.jev)
    #expect(both.current == .jev)
    var usageOnly = DashboardPages(enabled: [.usage])
    usageOnly.show(.jev)
    #expect(usageOnly.current == .usage)
    #expect(DashboardPages(current: .jev, enabled: [.usage]).current == .usage)
    #expect(DashboardPages(current: .usage, enabled: [.jev]).current == .jev)
}
