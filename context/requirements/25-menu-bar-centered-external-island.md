# Menu-bar-centered, compact external island

**Statement:** Center the non-notched island horizontally on its display and vertically within the menu-bar band when idle. Use `NSMenu.menuBarHeight`, not the nominal status-item thickness or the visible-frame reservation. Secondary displays and auto-hidden menus use the same virtual menu band. Resolve invalid, nonpositive or nonfinite menu heights to 24 pt. The idle pill is 130 pt wide and at most 24 pt tall (shrink to a smaller valid menu height); inset its top by half the remaining band height. The open body grows downward from that same top plane, not around the menu band's center.

The external open body is 452 pt wide with 14 pt horizontal content insets and a 424 pt content column. Do not reserve hardware shoulders or a camera gap on non-notched displays. Native hardware-notch geometry, 480 pt open width, 28 pt content insets and actual camera gap remain unchanged. The transparent hosting panel is not the visible island width.

Retain [21](21-follow-mouse-display.md)'s display choices, saved identity, disconnect recovery, debounce and interaction movement constraints. This supersedes [24](24-top-attached-external-island.md)'s physical-top attachment and the older external-placement clause in 21; it does not change project indexing or menu-bar hit-testing policy.

**Source:** User screenshots and explicit menu-bar centering/width request, 2026-10-10. Read-only AppKit inspection measured a 30 pt menu band versus 22 pt status-item thickness on the current external display.

**Compatibility:** Prefer the public main-menu instance metric when positive and finite. Accessory apps may have no main menu; the existing AppKit class selector supplies the system band through a narrowly ABI-checked getter bridge because Swift exposes only the instance property. If that selector is absent or incompatible, use the 24 pt fallback, not nominal status-item thickness.

**Status:** Current. Pure geometry tests and fixture rendering can verify arithmetic and layout only; actual installed-app placement, pointer interactions, auto-hide and multi-display behavior still require hardware validation.

**Where in code:** `Sources/IslandCore/DisplayChoice.swift`, `Sources/DynamicIsland/NotchController.swift`, `IslandView.swift`, `DashboardView.swift` and `Snapshots.swift`.
