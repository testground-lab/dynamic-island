# 0013: Keep usage history 183 days

- **Date:** 2026-10-03
- **Status:** accepted (supersedes the 31-day retention in [0004](0004-usage-history-sqlite.md))

## Context
Requirement 17 adds a 6-month range; 31 days of 15-minute buckets can't fill it.

## Decision
`UsageStore.retention` = 183 days, one constant used for the prune cutoff, the accepted-record window and the model cache. The hourly prune still deletes only buckets that start before the (bucket-rounded) cutoff. No schema change and no migration: existing buckets stay as they are; only the cutoff moved, so a database written by the 31-day version keeps all its rows. The 6m chart reads one 26-week scan; other ranges derive from it as before.

## Alternatives considered
Separate daily roll-up table for old data (more code, a migration); 31 days with 6m partly "not recorded" (useless range).

## Consequences
The database grows up to ~6x (15-minute buckets per account and model, only where there was traffic). 6m reports query more rows; still grouped in SQL. The first months after upgrading show "not recorded" before tracking began, as before. The model list behind the 200-model "other" fold now spans 183 days, so the fold is reached sooner. A clock set months ahead would prune by the wrong "now", as before; the larger window makes that worse but it stays out of scope.
