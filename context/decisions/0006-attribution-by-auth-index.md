# 0006: Per-account attribution via auth_index

- **Date:** 2026-10-02
- **Status:** accepted

## Context
Queue records carry `auth_index`, matching auth-files accounts.

## Decision
Attribute tokens per account by auth_index (exact for recorded requests). Unknown non-empty indexes show as "<Provider> account · <last4>"; empty index is "Unattributed".

## Alternatives considered
Estimating from per-account request counts.

## Consequences
Config API-key credentials aren't in auth-files, so they appear under the unknown-index label.
