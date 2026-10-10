# 0014: Index complete available local project usage

- **Date:** 2026-10-09
- **Status:** accepted

## Context
The Projects page should cover available supported local-session history, not stop at a permanent prefix of files or bytes. Re-reading the full retained corpus on every launch is unnecessary, while persisting raw logs or conversation content is unacceptable.

## Decision
Use a private local SQLite index at `Application Support/DynamicIsland/ProjectUsage/index.sqlite`, separate from CLIProxyAPI's `Application Support/DynamicIsland/usage.sqlite`. Persist only bounded source/file identity and verification metadata, committed newline offsets, session/response identities, timestamps, cwd, normalized token counters, and context needed to resume, deduplicate, and attribute usage. Keep directory and database sidecars private (0700 directory, 0600 database/WAL/SHM/journal files). Stream only required metadata; never store raw JSON rows or prompts, conversation/tool content, credentials, or other session content. Bound work per pass and resume from verified checkpoints instead of imposing a permanent total file/byte scan cap. Count only documented supported producer records; canonical Codex response IDs are the idempotency key. Legacy-only cumulative or repeated Codex token snapshots remain unsupported. See [requirement 23](../requirements/23-complete-project-usage-index.md) and [requirement 22](../requirements/22-project-usage.md).

## Consequences
The index represents only retained logs still available locally; deleting logs or missing/unsupported producer data cannot be repaired from proxy usage or inferred counters. Catch-up and verification may span passes and launches; progress/totals remain explicitly partial until complete, and can change as sources are reconciled. This decision does not claim corpus-wide producer compatibility or real-machine validation.
