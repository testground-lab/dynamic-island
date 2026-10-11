# Show the island on all displays

**Statement:** Settings offers **All displays** right after Follow mouse. It keeps one island on every connected display: the hardware notch on notched screens and the floating pill from [25](25-menu-bar-centered-external-island.md) elsewhere, so islands never move or disappear with the pointer. Each island opens and closes independently; clicking elsewhere closes an open one, and the page selection is shared. Islands are keyed by stable display UUID: a connected display gets one, a removed display's island is dismissed and torn down, and the rest are re-placed when the topology or Settings change. Leaving All displays restores the single-island path at its resolved target. `--menubar` still overrides it; `--expanded` applies to every island. With no displays it falls back to the menu-bar item. Follow mouse stays the default.

**Source:** User request, 2026-10-11.

**Status:** Current; multi-display hardware behavior unverified.

**Where in code:** `IslandCore/DisplayChoice.swift` (`DisplayPreference.allDisplays`, `DisplayTarget.allDisplayIDs`, `DisplayDiff`), `main.swift` (`layoutAllDisplays`), `SettingsView.swift`.
