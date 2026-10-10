# Top-attached island on external displays

**Statement:** On a non-notched external display, position the floating island flush to the physical top edge, centered horizontally, with no inset below the menu-bar band. Do not reserve or simulate a camera/notch gap on that display. A built-in display with a hardware notch continues to use its actual notch geometry. Centered menu-bar content may overlap the island's top-center area by design; this geometry decision does not establish or change menu-bar hit-testing or interaction behavior.

Retain [21](21-follow-mouse-display.md)'s Follow mouse / Automatic / fixed-display choices, saved display identity and disconnect fallback, 0.3-second settled-pointer debounce, and movement constraints for collapsed/emphasized, hover-open, pinned, and expanded states. This requirement supersedes only 21's 6 pt gap/menu-bar-band external-display placement clause; all other clauses remain current.

**Source:** User request, 2026-10-09.

**Status:** Superseded by [25](25-menu-bar-centered-external-island.md) for external placement and width. Display-follow and native-notch behavior remain unchanged. External-display placement and menu-bar interaction remain subject to real screen/hardware validation; do not present them as verified.

**Where in code:** `Sources/IslandCore/DisplayChoice.swift` and `Sources/DynamicIsland/NotchController.swift`.
