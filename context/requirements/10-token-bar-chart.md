# Token bar chart like Vorssaint

**Statement:** "I want a bar chart of token usage as well, like Vorssaint." Under the Usage total; Today hourly, 7d/30d daily; stacked by provider; pre-tracking periods shaded "not recorded".

**Source:** User request, 2026-10-02.

**Status:** current; extended by [17](17-six-month-range.md) and [19](19-account-filter.md). Unattributed series remain neutral per [12](12-unattributed-is-neutral.md).

**Where in code:** `Sources/DynamicIsland/TokenChart.swift`, `IslandCore/ChartLayout.swift`, `UsageStore.series`
