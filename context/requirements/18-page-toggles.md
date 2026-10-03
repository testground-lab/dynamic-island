# Show or hide each page in Settings

**Statement:** "Add a feature toggle inside the Settings page to enable or disable which page is showing and which page is not." Settings has a Pages section with one toggle per page, named by the page titles: "AI usage" and "Jev". Both on by default; saved in UserDefaults (`showUsagePage`, `showJevPage`), so the choice outlives the app. At least one page stays on: the last one shown can't be switched off (its toggle is disabled; a caption says so). Hiding a page only hides it: the CLIProxyAPI usage queue is still drained and saved and the Jev logs are still read, so turning a page back on shows what was collected meanwhile. With AI usage hidden, the Jev page's header still shows the connection dot when the proxy connection has a problem, so collection can't stop unnoticed. Hiding the open page switches to the remaining one at once, in the island and the menu-bar popover alike (they share one selection). With one page shown, the header keeps a single page dot (not clickable, hidden from VoiceOver; its tooltip names the hidden page) so its layout doesn't shift, and sideways swipes do nothing. The `--page jev` dev flag opens Jev only if it's shown, otherwise the shown page.

**Source:** User request, 2026-10-03.

**Status:** current (extends [16](16-swipe-pages-jev.md))

**Where in code:** `IslandCore/DashboardPages.swift` (shown pages, open page, swipe steps, persistence), `IslandView.swift` (`DashboardSelection`), `SettingsView.swift` (Pages section), `DashboardView.swift` (`PageDots`), `main.swift` (`--page`)
