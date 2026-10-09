# Account filter for AI usage

**Statement:** AI Usage offers All (default), a specific account, and Unattributed when present. The choice scopes totals, the token chart and By model across Today / 7d / 30d / 6m; Limits and Jev are unchanged. All keeps By account; specific scopes omit the redundant breakdown. Choices come from unfiltered six-month recorded history, with safe account labels, and the selected choice remains available if its history disappears. The choice is shared by island and popover during this launch, not persisted. Switching recomputes locally without polling; pending data is labelled as loading, never shown under the new scope. Empty/error states retain the selector and filtered empty history explains the chosen scope. Unattributed bars are neutral, including in All (fixing provider-colored unassigned chart data).

**Source:** User approval, 2026-10-09.

**Status:** current (extends [06](06-usage-by-account-and-model.md), [09](09-usage-never-silently-missing.md), [10](10-token-bar-chart.md); preserves [11](11-account-labels.md) and [12](12-unattributed-is-neutral.md)).

**Where in code:** `IslandCore/Domain.swift` (`UsageAccountFilter`, `UsageReport.filter`), `UsageStore.swift` (`report`, `accountUsage`, `seriesAll`), `IslandModel.swift` (`applyUsageFilter`), `DynamicIsland/DashboardView.swift`, `TokenChart.swift`.
