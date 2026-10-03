# Two swipe pages: AI usage, then Jev usage

**Statement:** "I also use Jev for development. Could I also add Jev usage inside the island? We could swipe to switch page." The open island has two pages, each about one thing: page one is the AI usage page of [07](07-single-scrolling-page.md) unchanged (Limits then Usage, one scrolling page); page two is Jev usage. Switch with a two-finger sideways swipe anywhere on the open island (fingers left = next) or by clicking the page dots beside the header title. Same fixed 480 x 262 size ([08](08-fixed-height.md)); the interactions of [0007](../decisions/0007-interactions.md) still hold (sideways strokes never open or close). The page and both range choices are remembered while the app runs (not across launches), shared by the island and the popover, so a display change that swaps them keeps them. The menu-bar popover has the same pages and swipe.

Jev page: Today / 7d / 30d / 6m picker ([17](17-six-month-range.md)); tokens (input + output) with requests, failed and late counts; estimated spend = input tokens x $0.042 / 1M (output free at the moment), labelled "est. spend", rate in one constant (`JevPricing`); the token bar chart of [10](10-token-bar-chart.md) (hourly Today, daily 7d/30d, weekly 6m, no "not recorded" shading); failures by error. Data: the jev-model-router hook's logs, see [0012](../decisions/0012-jev-usage-from-router-log.md). Never silently empty (spirit of [09](09-usage-never-silently-missing.md)): nothing logged yet, nothing in range (with last call), logs unreadable (reason), some log files unreadable (warning above the totals), first read pending.

**Source:** User request, 2026-10-03.

**Status:** current (supersedes [07](07-single-scrolling-page.md) only in part: the "no page dots or sideways swipe" clause; extended by [18](18-page-toggles.md): either page can be hidden in Settings)

**Where in code:** `DashboardView.swift` (`pages`, `PageDots`, `ScrollingPage`), `JevPage.swift`, `IslandCore/JevUsage.swift`, `IslandCore/Interaction.swift` (`DashboardPage`), `IslandCore/DashboardPages.swift` (swipe steps), `NotchController.scrolled`, `MenuBarController.installSwipeMonitor`
