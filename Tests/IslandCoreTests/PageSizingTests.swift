import CoreGraphics
import Testing
@testable import IslandCore

@Test func islandViewportIsTotalMinusChrome() {
    // 262 pt island, 38 pt camera-tall header, 6 pt gap, 14 pt bottom inset.
    #expect(PageSizing.viewport(total: 262, header: 38, spacing: 6, chrome: 14) == 204)
}

@Test func popoverViewportUsesItsOwnChrome() {
    // Same 262 pt height; 22 pt header, 6 pt gap, 12 + 12 pt padding.
    #expect(PageSizing.viewport(total: 262, header: 22, spacing: 6, chrome: 24) == 210)
}

@Test func viewportDoesNotDependOnContent() {
    // The rule has no content input: a tall notch only shrinks the page.
    let short = PageSizing.viewport(total: 262, header: 32, spacing: 6, chrome: 14)
    let tall = PageSizing.viewport(total: 262, header: 44, spacing: 6, chrome: 14)
    #expect(short - tall == 12)
}

@Test func viewportNeverNegative() {
    #expect(PageSizing.viewport(total: 40, header: 38, spacing: 6, chrome: 14) == 0)
}
