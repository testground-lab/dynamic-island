import Foundation
import Testing

@testable import IslandCore

@Test func allPagesShownByDefault() {
    let pages = DashboardPages(defaults: VolatileDefaults())
    #expect(pages.shown == [.usage, .jev, .projects])
    #expect(pages.current == .usage)
    #expect(DashboardPage.allCases.allSatisfy { !pages.isLocked($0) })
}

@Test func shownPagesPersist() {
    let defaults = VolatileDefaults()
    var pages = DashboardPages()
    pages.setEnabled(.jev, false)
    pages.setEnabled(.projects, false)
    pages.save(to: defaults)
    #expect(defaults.object(forKey: "showUsagePage") as? Bool == true)
    #expect(defaults.object(forKey: "showJevPage") as? Bool == false)
    #expect(defaults.object(forKey: "showProjectsPage") as? Bool == false)
    #expect(DashboardPages(defaults: defaults).shown == [.usage])

    pages.setEnabled(.jev, true)
    pages.setEnabled(.usage, false)
    pages.save(to: defaults)
    let restored = DashboardPages(defaults: defaults)
    #expect(restored.shown == [.jev])
    #expect(restored.current == .jev)
    pages.setEnabled(.projects, true)
    pages.setEnabled(.jev, false)
    pages.save(to: defaults)
    #expect(DashboardPages(defaults: defaults).shown == [.projects])
}

@Test func savedStateWithNoPageShowsAll() {
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "showUsagePage")
    defaults.set(false, forKey: "showJevPage")
    defaults.set(false, forKey: "showProjectsPage")
    #expect(DashboardPages(defaults: defaults).shown == DashboardPage.allCases)
    #expect(DashboardPages(enabled: []).shown == DashboardPage.allCases)
}

@Test func nonBoolSavedValueHidesOnlyThatPage() {
    let defaults = VolatileDefaults()
    defaults.set("garbage", forKey: "showJevPage")
    #expect(DashboardPages(defaults: defaults).shown == [.usage, .projects])
    defaults.set(["x"], forKey: "showUsagePage")
    #expect(DashboardPages(defaults: defaults).shown == [.projects])
    defaults.set("garbage", forKey: "showProjectsPage")
    #expect(DashboardPages(defaults: defaults).shown == DashboardPage.allCases) // never zero pages
}

@Test(arguments: DashboardPage.allCases)
func theLastShownPageCantBeHidden(_ only: DashboardPage) {
    var pages = DashboardPages(enabled: [only])
    #expect(pages.isLocked(only))
    pages.setEnabled(only, false)
    #expect(pages.shown == [only])
    #expect(pages.current == only)
    for other in DashboardPage.allCases where other != only {
        #expect(!pages.isLocked(other))
        pages.setEnabled(other, true)
        #expect(!pages.isLocked(only))
    }
    #expect(pages.shown == DashboardPage.allCases)
}

@Test(arguments: DashboardPage.allCases)
func hidingTheOpenPageOpensTheFirstRemaining(_ open: DashboardPage) {
    var pages = DashboardPages(current: open)
    pages.setEnabled(open, false)
    let remaining = DashboardPage.allCases.filter { $0 != open }
    #expect(pages.current == remaining.first)
    #expect(pages.shown == remaining)
}

@Test func hidingAnotherPageKeepsTheOpenOne() {
    var pages = DashboardPages(current: .jev)
    pages.setEnabled(.usage, false)
    #expect(pages.current == .jev)
    pages.setEnabled(.projects, false)
    #expect(pages.current == .jev)
}

private func swipe(_ pages: DashboardPages, _ actions: [ScrollGestureAction]) -> ([Bool], DashboardPage) {
    var pages = pages
    let moved = actions.map { pages.apply($0) }
    return (moved, pages.current)
}

@Test func swipesStepThroughShownPagesAndStopAtTheEnds() {
    let (moved, end) = swipe(DashboardPages(), [.previousPage, .nextPage, .nextPage, .nextPage, .open, .close])
    #expect(moved == [false, true, true, false, false, false])
    #expect(end == .projects)
    let (back, start) = swipe(DashboardPages(current: .projects), [.previousPage, .previousPage, .previousPage])
    #expect(back == [true, true, false])
    #expect(start == .usage)
    let (skipHidden, second) = swipe(DashboardPages(enabled: [.usage, .projects]), [.nextPage, .nextPage])
    #expect(skipHidden == [true, false] && second == .projects)
}

@Test(arguments: DashboardPage.allCases)
func onePageIgnoresSwipesAndDots(_ only: DashboardPage) {
    var pages = DashboardPages(enabled: [only])
    #expect(pages.shown == [only])
    let (moved, end) = swipe(pages, [.nextPage, .previousPage])
    #expect(moved == [false, false])
    #expect(end == only)
    for page in DashboardPage.allCases {
        pages.show(page)
        #expect(pages.current == only)
    }
}

@Test func requestedPageFallsBackWhenHidden() {
    var all = DashboardPages()
    all.show(.projects)
    #expect(all.current == .projects)
    var usageOnly = DashboardPages(enabled: [.usage])
    usageOnly.show(.projects)
    #expect(usageOnly.current == .usage)
    #expect(DashboardPages(current: .jev, enabled: [.usage]).current == .usage)
    #expect(DashboardPages(current: .usage, enabled: [.projects]).current == .projects)
}

@Test func oldTwoPagePreferencesKeepChoicesAndEnableNewProjectsPage() {
    let defaults = VolatileDefaults()
    defaults.set(false, forKey: "showUsagePage")
    defaults.set(true, forKey: "showJevPage")
    #expect(DashboardPages(defaults: defaults).shown == [.jev, .projects])
    #expect(DashboardPages(defaults: defaults).current == .jev)
}
