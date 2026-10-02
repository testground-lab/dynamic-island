# Usage must never silently disappear

**Statement:** "Usage is missing": the Usage section always renders and explains why it's empty (no key, key rejected, proxy down, poll failed, queue 404/error, waiting, nothing in range). Recorded history always wins over a transient problem.

**Source:** User feedback, 2026-10-02.

**Status:** current

**Where in code:** `IslandCore/UsageState.swift`, `IslandModel.usageState(for:)`, `DashboardView.swift`
