# Context

Requirements and decisions for this project, one per file, so new sessions have everything discussed.

## How to use
- Read this index, then the files relevant to your task.
- When a requirement or decision changes, add a new file (next number), mark the old one **superseded** (link the new one); don't delete.
- Keep each file short: statement or decision, source/date, status, where it lives in code.

## Requirements
- [01-notch-island-for-cliproxyapi](requirements/01-notch-island-for-cliproxyapi.md): Notch dynamic island for CLIProxyAPI
- [02-quota-and-usage](requirements/02-quota-and-usage.md): Show quota per account and live usage
- [03-project-location](requirements/03-project-location.md): Project location
- [04-compact-like-vorssaint](requirements/04-compact-like-vorssaint.md): Compact, look and behave like Vorssaint's island
- [05-idle-shows-only-notch](requirements/05-idle-shows-only-notch.md): Idle island is just the notch
- [06-usage-by-account-and-model](requirements/06-usage-by-account-and-model.md): Usage for all accounts and by model, Today/7d/30d
- [07-single-scrolling-page](requirements/07-single-scrolling-page.md): One page: Limits then Usage, scroll instead of pages (partly superseded by 16)
- [08-fixed-height](requirements/08-fixed-height.md): Fixed height, scroll inside
- [09-usage-never-silently-missing](requirements/09-usage-never-silently-missing.md): Usage must never silently disappear
- [10-token-bar-chart](requirements/10-token-bar-chart.md): Token bar chart like Vorssaint
- [11-account-labels](requirements/11-account-labels.md): Never show raw auth file names
- [12-unattributed-is-neutral](requirements/12-unattributed-is-neutral.md): "Unattributed" usage is neutral
- [13-collapsed-live-strip](requirements/13-collapsed-live-strip.md): Collapsed strip with live quota and req/h (superseded)
- [14-two-pages](requirements/14-two-pages.md): Separate Limits and Usage pages (superseded)
- [15-height-up-to-60-percent](requirements/15-height-up-to-60-percent.md): Open island grows up to 60% of the screen (superseded)
- [16-swipe-pages-jev](requirements/16-swipe-pages-jev.md): Two swipe pages: AI usage, then Jev usage
- [17-six-month-range](requirements/17-six-month-range.md): 6m range (weekly bars) on both pages
- [18-page-toggles](requirements/18-page-toggles.md): Show or hide each page in Settings (one always stays on)

## Decisions
- [0001-native-swiftui-lsuielement](decisions/0001-native-swiftui-lsuielement.md): Native SwiftUI app, LSUIElement
- [0002-management-key-in-keychain](decisions/0002-management-key-in-keychain.md): Management key in Keychain only
- [0003-endpoints](decisions/0003-endpoints.md): Management endpoints used
- [0004-usage-history-sqlite](decisions/0004-usage-history-sqlite.md): Persist usage as 15-minute buckets in SQLite (retention superseded by 0013)
- [0005-web-panel-competes](decisions/0005-web-panel-competes.md): The CLIProxyAPI web panel competes for queue records
- [0006-attribution-by-auth-index](decisions/0006-attribution-by-auth-index.md): Per-account attribution via auth_index
- [0007-interactions](decisions/0007-interactions.md): Interaction model
- [0008-vorssaint-gpl-reimplement](decisions/0008-vorssaint-gpl-reimplement.md): Vorssaint is GPL-3.0: reimplement, don't copy
- [0009-token-chart](decisions/0009-token-chart.md): Token chart with Swift Charts
- [0010-macos-15-minimum](decisions/0010-macos-15-minimum.md): macOS 15 minimum
- [0011-review-process](decisions/0011-review-process.md): Review process
- [0012-jev-usage-from-router-log](decisions/0012-jev-usage-from-router-log.md): Jev usage from the router's local log, not the console API
- [0013-usage-retention-183-days](decisions/0013-usage-retention-183-days.md): Keep usage history 183 days

## Open items
- [open-items](open-items.md): undecided labels and what still needs checking on screen
