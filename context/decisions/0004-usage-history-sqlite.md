# 0004: Persist usage as 15-minute buckets in SQLite

- **Date:** 2026-10-02
- **Status:** accepted; retention superseded by [0013](0013-usage-retention-183-days.md) (31 → 183 days)

## Context
The usage queue is a destructive read with ~60 s retention; 7d/30d need local history.

## Decision
Drain the queue every 15 s and aggregate into `~/Library/Application Support/DynamicIsland/usage.sqlite`: 15-min buckets keyed by (start, auth_index, model) with provider and counts, kept 31 days. Never store client API keys, IPs, user agents or response headers. 'Tracking since' marks where history starts; failed writes are kept as bounded aggregates.

## Alternatives considered
In-memory/JSON aggregates (lost history, no accounts); raw records (privacy).

## Consequences
History only covers time the app was running; the old usage.json was dropped, not migrated.
