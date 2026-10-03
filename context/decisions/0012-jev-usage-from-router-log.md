# 0012: Jev usage from the router's local log

- **Date:** 2026-10-03
- **Status:** accepted

## Context
Requirement 16. The Jev console shows all Jev traffic comes from one API key, used by the global jev-model-router Claude Code hook. The console's own usage data sits behind `/api/usage`, which is undocumented, needs a session cookie and is behind Cloudflare.

## Decision
Read `~/.claude/jev-model-router/usage.jsonl`, which the hook appends one JSON object per call to (`ts`, `model`, `input_tokens`, `output_tokens`, `latency_ms`, `ok`, `error`; keeps at least 35 days, prunes via temp file + rename). Read-only; malformed or partial lines and unknown fields are skipped; a missing file is a normal state. A 10 s poll stats the file (inode, size, mtime) off the main thread and re-reads only on change; reports are recomputed on change or when the hour rolls over. Files over 64 MB are refused.

## Alternatives considered
The console's cookie-authenticated `/api/usage` (undocumented, cookie handling, Cloudflare); a file-system watcher (the file is replaced by rename and may not exist yet; a cheap stat poll is simpler).

## Consequences
Only calls made through the router are counted, and only since the hook started logging; before that the chart shows zeros, not "not recorded". Spend is an estimate from a hard-coded rate.
