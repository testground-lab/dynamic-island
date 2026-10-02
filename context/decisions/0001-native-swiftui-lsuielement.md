# 0001: Native SwiftUI app, LSUIElement

- **Date:** 2026-10-02
- **Status:** accepted

## Context
A notch overlay needs an always-on-top borderless panel and no Dock icon.

## Decision
Swift 6 SwiftPM package: `IslandCore` (models, networking, storage, state, all tested) + `DynamicIsland` (AppKit/SwiftUI UI). `.accessory` activation policy; `scripts/bundle.sh` builds an ad-hoc-signed LSUIElement .app (needed for launch at login).

## Alternatives considered
Electron/web (heavy, poor notch integration); Xcode project (harder to build from CLI).

## Consequences
Builds with `swift build`; Settings temporarily switches to `.regular` so the key field can take focus.
