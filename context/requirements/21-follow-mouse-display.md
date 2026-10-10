# Follow the mouse or choose a display

**Statement:** With no saved display preference, **Follow mouse** is the default target. Settings also offers **Automatic** (use the existing notched-display/menu-bar fallback) and fixed-display choices. A fixed display that disconnects falls back to follow-mouse without erasing the saved UUID, so reconnecting restores that choice; `--menubar` still overrides it. Reposition only after the pointer has settled on another display for 0.3 seconds, and only while the island is collapsed or emphasized. Before a move, close a hover-open island normally; a click-pinned or expanded island stays on its current display until closed. If its active display disappears, recover to an available target.

On a display without a notch, place the pill at top center below the reserved menu-bar band, including when that display auto-hides its menu bar, with a 6 pt gap. Recompute placement when the topology changes even if the display UUID is unchanged.

**Source:** User request, 2026-10-09.

**Status:** Current except the 6 pt gap/menu-bar-band external-display placement, which is superseded by [25](25-menu-bar-centered-external-island.md) (after [24](24-top-attached-external-island.md)). Follow-mouse, saved choice, disconnect recovery, debounce, and pinned/expanded movement constraints remain current. Supersedes [20](20-display-selector.md)'s default-target and disconnect-fallback clauses; its saved stable display UUID and name remain valid. Screen and hardware behavior still need verification.

**Where in code:** `IslandCore/DisplayChoice.swift`, `SettingsView.swift`, `main.swift`, `NotchController.swift` (display identity, target, placement, and interaction state).
