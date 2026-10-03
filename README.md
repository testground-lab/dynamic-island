# Dynamic Island for CLIProxyAPI

A notch "dynamic island" for a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) gateway:
per-account plan limits (Claude / Codex windows and reset times) and token usage by account and model
for today, 7 days, 30 days and 6 months, plus a second page with [Jev usage](#jev).
On displays without a notch it lives in the menu bar.

## Build and run

```sh
swift build && swift test
swift run DynamicIsland            # real mode: paste the management key in Settings (stored in Keychain)
swift run DynamicIsland --demo     # bundled fixtures, no network
swift run DynamicIsland --demo --page jev --range halfYear   # start on the Jev page, 6m range
swift run DynamicIsland --snapshot /tmp/shots   # render demo PNGs and exit
scripts/bundle.sh                  # build/DynamicIsland.app (needed for launch at login)
```

Other development flags (`--expanded`, `--menubar`, `--jev-dir <dir>`) are listed in `Sources/DynamicIsland/main.swift`.

Click the notch (or swipe down on it with two fingers) to open; click elsewhere, press Esc or swipe up on its top row to close.
Inside there are two pages: **AI usage** (Limits, then Usage; scroll to see more) and **Jev**. Switch with a two-finger
sideways swipe or by clicking the page dots next to the title; the menu-bar popover has the same pages.
Both pages offer Today / 7d / 30d / 6m; 6m shows 26 weekly bars. "Open on hover" is available in Settings.

## Data

- `GET /v0/management/auth-files`: accounts, status, cooldowns, rate-limit headers.
- `POST /v0/management/api-call`: optional live quota from the Claude/Codex usage endpoints (every 5 min).
- `GET /v0/management/usage-queue`: per-request records, drained every 15 s and aggregated into
  `~/Library/Application Support/DynamicIsland/usage.sqlite` (15-minute buckets per account and model, kept 183 days;
  no API keys, IPs or user agents are stored). The prune is skipped while the clock is more than 2 days past the newest
  stored usage, so a clock briefly set far ahead doesn't wipe the history (see context/decisions/0013).

**The usage queue is a destructive read.** The proxy keeps each record about 60 seconds and gives it to the first
reader. If the CLIProxyAPI web panel or another tool reads the queue at the same time, records are split between
them and every reader undercounts. Usage before the app started is not available ("tracking since" in the UI).

## Jev

The Jev page counts calls made through the jev-model-router hook, a separate Claude Code hook (not part of this repo)
that calls Jev and logs each call. It shows tokens in and out, requests, failed calls and late ones (answered after the
hook's timeout, still billed, so counted in tokens and spend), and an estimated spend of $0.042 per 1M input tokens
(output is free at the moment; the rate is `JevPricing` in `Sources/IslandCore/JevUsage.swift`).

It reads the hook's per-session logs, `~/.claude/jev-model-router/usage-*.jsonl` (one JSON line per call), every 10 s,
read-only. Without the hook the page says nothing has been logged yet; calls made before the hook started logging,
or outside it, are not counted. See context/decisions/0012.

## Troubleshooting

AI usage stays empty until a management key is saved in Settings: without one the app never reads the queue.
The Jev page doesn't need the key.
Queue reads are logged (counts and status only, never the key):

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "dev.ksotis.dynamic-island"'
```

## License

GPL-3.0. See [LICENSE](LICENSE).
