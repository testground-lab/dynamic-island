# 0003: Management endpoints used

- **Date:** 2026-10-02
- **Status:** accepted

## Context
CLIProxyAPI v8.0.5. `/v0/management/usage` does not exist in v8 (its 401 came from the auth middleware before the 404).

## Decision
Use `GET /v0/management/auth-files` (accounts, status, cooldowns, passive rate-limit headers, recent requests) every 15 s; `GET /v0/management/usage-queue` every 15 s; optional `POST /v0/management/api-call` live quota (Claude oauth/usage, Codex wham/usage, hard-coded URLs) per account every 5 min.

## Alternatives considered
Plugin quota endpoints (plugins disabled on this proxy).

## Consequences
Claude/Codex quota is exact when fresh; other providers report no quota.
