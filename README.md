# Dynamic Island for CLIProxyAPI

A notch "dynamic island" for a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) gateway:
per-account plan limits (Claude / Codex windows and reset times) and token usage by account and model
for today, 7 days, 30 days and 6 months, plus [Jev usage](#jev) and [local project usage](#projects) pages.
The default **Follow mouse** mode moves the island with the pointer. Settings also offers **Automatic** (a notched display, or the menu-bar fallback) and fixed connected displays. A fixed display that disconnects falls back to Follow mouse without erasing the saved choice. Nonnotched displays use a floating pill centered in the menu-bar band, with a compact open body and no hardware-notch shoulders; `--menubar` overrides the saved display choice.

## Build and run

```sh
swift build && swift test
swift run DynamicIsland            # real mode: paste the management key in Settings (stored in Keychain)
swift run DynamicIsland --demo     # bundled fixtures, no network
swift run DynamicIsland --demo --page jev --range month   # start on the Jev page, 30d range
swift run DynamicIsland --snapshot /tmp/shots   # render demo PNGs and exit
scripts/bundle.sh                  # build/DynamicIsland.app (needed for launch at login)
```

Other development flags (`--expanded`, `--menubar`, `--jev-dir <dir>`) are listed in `Sources/DynamicIsland/main.swift`.

Click the notch (or swipe down on it with two fingers) to open; click elsewhere, press Esc or swipe up on its top row to close.
Inside there are three pages: **AI usage** (Limits, then Usage; scroll to see more), **Jev**, and **Projects**. Switch with a two-finger
sideways swipe or by clicking the page dots next to the title; the menu-bar popover has the same pages.
AI Usage and Jev offer Today / 7d / 30d / 6m; their 6m charts show 26 weekly bars. Projects offers the same ranges without a chart. "Open on hover" is available in Settings.
AI Usage also filters totals, chart and By model by account (All by default, or Unattributed); Limits and Jev are unaffected.

## Data

- `GET /v0/management/auth-files`: accounts, status, cooldowns, rate-limit headers.
- `POST /v0/management/api-call`: optional live quota from the Claude/Codex usage endpoints (every 5 min).
- `GET /v0/management/usage-queue`: per-request records, drained every 15 s and aggregated into
  `~/Library/Application Support/DynamicIsland/usage.sqlite` (15-minute buckets per account and model, kept 183 days;
  no API keys, IPs or user agents are stored). The prune is skipped while the clock is more than 2 days past the newest
  stored usage, so a clock set far ahead can't wipe the history on its first prune (see context/decisions/0013).

**The usage queue is a destructive read.** The proxy keeps each record about 60 seconds and gives it to the first
reader. If the CLIProxyAPI web panel or another tool reads the queue at the same time, records are split between
them and every reader undercounts. Usage before the app started is not available ("recorded since" in the UI).

## Jev

The Jev page counts calls to Jev (TypeSafe's model) made through the jev-model-router hook, a separate Claude Code hook
(not part of this repo) that calls Jev and logs each call. It shows tokens in and out, requests, failed calls and late
ones (answered after the router's timeout, still billed, so counted in tokens and spend), and an estimated spend of
$0.042 per 1M input tokens (output is free at the moment; the rate is `JevPricing` in `Sources/IslandCore/JevUsage.swift`).

It reads the hook's per-session logs, `~/.claude/jev-model-router/usage-*.jsonl` (one JSON line per call), every 10 s,
read-only. Without the hook the page says nothing has been logged yet; calls made before the hook started logging,
or outside it, are not counted. See context/decisions/0012.

## Projects

The Projects page reports local Claude Code and Codex usage by project, with All / Claude Code / Codex source choices and Today / 7d / 30d / 6m ranges. It shows input, output, cache-read and cache-creation tokens and response counts, ranking projects with neutral meters. It does not estimate cost or add charts.

It indexes available supported history from JSONL files under `~/.claude/projects/` and `~/.codex/sessions/`, read-only and without a management key. A first full catch-up can take several minutes; progress and partial totals are shown until it finishes. A private metadata-only local index resumes across launches, reuses verified unchanged-file results and checks for new or changed logs without reparsing all history. Totals cover all indexed projects, not just the current page; projects are ranked and shown 20 at a time with Previous / Next navigation. Project attribution uses the session's absolute working directory; missing or ambiguous paths are Unattributed, and worktrees remain separate. This is local-session usage, not CLIProxyAPI queue attribution, and is never added to proxy totals. Prompts and conversation text are not retained, stored or logged. Conflicting, unsupported, future-dated, malformed, or unreadable source data can produce explicit warnings; local logs deleted before indexing cannot be reconstructed. See context/requirements/22-project-usage.md and [23](context/requirements/23-complete-project-usage-index.md).

## Troubleshooting

AI usage stays empty until a management key is saved in Settings: without one the app never reads the queue.
The Jev page doesn't need the key.
Queue reads are logged (counts and status only, never the key):

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "dev.ksotis.dynamic-island"'
```

## License

GPL-3.0. See [LICENSE](LICENSE).
