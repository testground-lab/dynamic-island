# 0012: Jev usage from the router's local logs

- **Date:** 2026-10-03
- **Status:** accepted

## Context
Requirement 16. The Jev console shows all Jev traffic comes from one API key, used by the global jev-model-router Claude Code hook. The console's own usage data sits behind `/api/usage`, which is undocumented, needs a session cookie and is behind Cloudflare.

## Decision
Read the hook's logs in `~/.claude/jev-model-router/`: one JSON object per call per line (`ts`, `model`, `input_tokens`, `output_tokens`, `latency_ms`, `ok`, `error`), one file per session (`usage-<session-id>.jsonl`, rotated to `usage-<session-id>.N.jsonl` near 3 MiB), each rewritten whole on every call, lines not ordered by `ts` (late answers are appended later); files whose newest line is over 183 days old are deleted. Only `usage-*.jsonl` is read (the `.last-prune` marker and anything else are ignored). Tokens and spend count from every line; `ok:false` with 0 tokens is a failure, `ok:false` with tokens (a timeout answered late, still billed) is shown as "late", not failed. Read-only; malformed or partial lines and unknown fields are skipped; no folder or no files is a normal "not logged yet" state; a log with lines but none recognisable shows as unreadable, so a format change can't pass for "no calls". A 10 s poll lists the folder off the main thread, skips files not modified within the widest range (6m, ~183 days; if only older files exist the page says "no calls in this range" with the newest file's time), re-reads only files whose inode, size, mtime or ctime changed (`stat`, so symlinks work). A file deleted mid-scan is just gone. Reports are built off the main thread too; reports are also rebuilt when the hour rolls over. A file that can't be read (or is over 64 MB) is skipped and the page warns that totals are incomplete; more than 64 MB in total is refused.

## Alternatives considered
The console's cookie-authenticated `/api/usage` (undocumented, cookie handling, Cloudflare); a file-system watcher (files are created and rewritten per session and the folder may not exist yet; a cheap stat poll is simpler); the single `usage.jsonl` first planned (the writer chose per-session files so concurrent sessions can't lose lines).

## Consequences
Only calls made through the router are counted, and only since the hook started logging; before that the chart shows zeros, not "not recorded". Spend is an estimate from a hard-coded rate.
