# Six-month range on both pages

**Statement:** The user asked for a 6-month range on both pages: Usage (CLIProxyAPI) and Jev get Today / 7d / 30d / 6m. 6m shows 26 calendar weeks (the current week last, weeks start on the locale's first weekday) as weekly bars, the same on both pages: ~183 daily bars don't read at 480 pt. Totals cover the same 26 weeks. Usage history is kept 183 days ([0013](../decisions/0013-usage-retention-183-days.md)); the Jev router keeps its logs 183 days.

**Source:** User request, 2026-10-03.

**Status:** current (extends [06](06-usage-by-account-and-model.md), [10](10-token-bar-chart.md) and [16](16-swipe-pages-jev.md))

**Where in code:** `IslandCore/UsageStore.swift` (`retention`), `IslandCore/Domain.swift` (`UsageRange.halfYear`, `chartEnd`, `UsageGranularity.week`), `IslandCore/SeriesBinning.swift`, `IslandCore/ChartLayout.swift`, `TokenChart.swift`
