import Foundation

/// Which dashboard pages are shown (chosen in Settings) and which one is open.
/// At least one page is always shown, and the open page is always a shown one.
/// Hiding a page only hides it: its data keeps being collected.
public struct DashboardPages: Equatable, Sendable {
    public private(set) var current: DashboardPage
    public private(set) var enabled: Set<DashboardPage>

    public init(current: DashboardPage = .usage, enabled: Set<DashboardPage> = Set(DashboardPage.allCases)) {
        self.enabled = enabled.isEmpty ? Set(DashboardPage.allCases) : enabled
        self.current = current
        show(current)
    }

    /// Shown pages in swipe order.
    public var shown: [DashboardPage] { DashboardPage.allCases.filter(enabled.contains) }

    public func isEnabled(_ page: DashboardPage) -> Bool { enabled.contains(page) }

    /// The last shown page can't be hidden.
    public func canDisable(_ page: DashboardPage) -> Bool { !isEnabled(page) || enabled.count > 1 }

    /// Shows or hides a page; hiding the open page opens the remaining one.
    public mutating func setEnabled(_ page: DashboardPage, _ isOn: Bool) {
        if isOn {
            enabled.insert(page)
        } else if canDisable(page) {
            enabled.remove(page)
            show(current)
        }
    }

    /// Opens `page`, or the first shown page when it's hidden.
    public mutating func show(_ page: DashboardPage) {
        current = isEnabled(page) ? page : shown[0]
    }

    /// Steps to the next or previous shown page. Returns false when there is
    /// none (the end of the list, a single page, or not a paging action).
    public mutating func apply(_ action: ScrollGestureAction) -> Bool {
        let pages = shown
        guard let index = pages.firstIndex(of: current) else { return false }
        let target: Int
        switch action {
        case .nextPage: target = index + 1
        case .previousPage: target = index - 1
        case .open, .close: return false
        }
        guard pages.indices.contains(target) else { return false }
        current = pages[target]
        return true
    }
}

extension DashboardPages {
    static func defaultsKey(_ page: DashboardPage) -> String {
        switch page {
        case .usage: "showUsagePage"
        case .jev: "showJevPage"
        }
    }

    /// The shown pages saved in `defaults`; a page never set is shown.
    public init(defaults: UserDefaults) {
        let enabled = DashboardPage.allCases.filter {
            let key = Self.defaultsKey($0)
            return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }
        self.init(enabled: Set(enabled))
    }

    public func save(to defaults: UserDefaults) {
        for page in DashboardPage.allCases {
            defaults.set(isEnabled(page), forKey: Self.defaultsKey(page))
        }
    }
}
