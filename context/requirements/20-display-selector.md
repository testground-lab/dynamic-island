# Choose the island display

**Statement:** Settings offers Automatic and connected displays (built-in marked). Automatic keeps the existing first-notched-display / menu-bar fallback. An explicitly selected display without a notch gets a top-centered black floating pill, 130 x 24 idle, 6 pt below the visible top edge; expanded content stays 480 pt wide with the existing fixed height and 424 pt content. It has rounded corners, a 28 pt header and no camera gap or camera-click close area. Existing hover, click, Escape, swipe and click-through behavior is retained. Stable display UUID and name are saved; disconnecting falls back to Automatic without erasing the choice, so reconnecting restores it. Settings lists a saved missing display as not connected. Screen changes and selection changes relayout immediately. `--menubar` still overrides the choice.

**Source:** User approval, 2026-10-09.

**Status:** current (extends [04](04-compact-like-vorssaint.md); supersedes [05](05-idle-shows-only-notch.md) only for an explicitly selected nonnotched display). UI and real hardware behavior remain unverified.

**Where in code:** `IslandCore/DisplayChoice.swift` (preference persistence, pure target resolver), `DynamicIsland/SettingsView.swift`, `main.swift`, `NotchController.swift` (screen identity, placement, hit-testing), `IslandView.swift` (floating outline).
