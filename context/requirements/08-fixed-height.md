# Fixed height, scroll inside

**Statement:** "The height should be the same, but I could scroll up and down inside." Open island and menu-bar popover are 480 x 262 pt regardless of content; the page scrolls inside; header row pinned; edge fades.

**Source:** User feedback, 2026-10-02.

**Status:** current (supersedes the 'grow up to 60% of screen' sizing)

**Where in code:** `Theme.openHeight`, `IslandCore/PageSizing.swift`, `DashboardView.swift`
