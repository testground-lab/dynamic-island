# 0013: Keep usage history 183 days

- **Date:** 2026-10-03
- **Status:** accepted (supersedes the 31-day retention in [0004](0004-usage-history-sqlite.md))

## Context
Requirement 17 adds a 6-month range; 31 days of 15-minute buckets can't fill it.

## Decision
`UsageStore.retention` = 183 days, one constant used for the prune cutoff, the accepted-record window and the model cache. The hourly prune still deletes only buckets that start before the (bucket-rounded) cutoff. No schema change and no migration: existing buckets stay as they are; only the cutoff moved, so a database written by the 31-day version keeps all its rows. The 6m chart reads one 26-week scan; other ranges derive from it as before.

## Verification
`RetentionTests` (rows aged 1/32/100/182 days kept, 184 pruned; a file written with the old schema reopened; strict rounded cutoff; 6m start never past retention; clock guard) and the env-gated `DI_DB_COPY` test, run on copies of the real database: as-is 142 → 142, half aged 200 days with recent rows 142 → 71, all aged (no recent usage) 142 → 142. The 31-day build turns a 60-day-aged copy from 142 rows into 0.

## Alternatives considered
Separate daily roll-up table for old data (more code, a migration); 31 days with 6m partly "not recorded" (useless range).

## Consequences
The database grows up to ~6x (15-minute buckets per account and model, only where there was traffic). 6m reports query more rows; still grouped in SQL. The first months after upgrading show "not recorded" before tracking began, as before. The model list behind the 200-model "other" fold now spans 183 days, so the fold is reached sooner. The prune is skipped while the clock is more than 2 days past the newest stored bucket (`pruneClockTolerance`), so a clock set months ahead can't wipe the history on its first prune; after a long break the prune waits for new usage. Records written while the clock is wrong still count as history afterwards, so a clock that stays wrong for over an hour of use is not protected.
