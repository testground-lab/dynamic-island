# 0005: The CLIProxyAPI web panel competes for queue records

- **Date:** 2026-10-02
- **Status:** accepted

## Context
Each queue record goes to whoever reads it first.

## Decision
Document it in Settings and README; no workaround.

## Alternatives considered
Coordinating with the panel (not possible).

## Consequences
If the panel or another tool reads the queue, both undercount.
