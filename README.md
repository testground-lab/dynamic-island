# Dynamic Island for CLIProxyAPI

A notch "dynamic island" for a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) gateway:
per-account plan limits (Claude / Codex windows and reset times) and token usage by account and model
for today, 7 days and 30 days. On displays without a notch it lives in the menu bar.

## Build and run

```sh
swift build && swift test
swift run DynamicIsland            # real mode: paste the management key in Settings (stored in Keychain)
swift run DynamicIsland --demo     # bundled fixtures, no network
swift run DynamicIsland --snapshot /tmp/shots   # render demo PNGs and exit
scripts/bundle.sh                  # build/DynamicIsland.app (needed for launch at login)
```

Click the notch (or swipe down on it with two fingers) to open; click elsewhere, press Esc or swipe up on its top row to close.
Inside, Limits and Usage share one page; scroll to see more. "Open on hover" is available in Settings.

## Data

- `GET /v0/management/auth-files`: accounts, status, cooldowns, rate-limit headers.
- `POST /v0/management/api-call`: optional live quota from the Claude/Codex usage endpoints (every 5 min).
- `GET /v0/management/usage-queue`: per-request records, drained every 15 s and aggregated into
  `~/Library/Application Support/DynamicIsland/usage.sqlite` (15-minute buckets per account and model, kept 183 days, see context/decisions/0013;
  no API keys, IPs or user agents are stored).

**The usage queue is a destructive read.** The proxy keeps each record about 60 seconds and gives it to the first
reader. If the CLIProxyAPI web panel or another tool reads the queue at the same time, records are split between
them and every reader undercounts. Usage before the app started is not available ("tracking since" in the UI).

## Troubleshooting

Usage stays empty until a management key is saved in Settings: without one the app never reads the queue.
Queue reads are logged (counts and status only, never the key):

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "dev.ksotis.dynamic-island"'
```

## License

GPL-3.0. See [LICENSE](LICENSE).
