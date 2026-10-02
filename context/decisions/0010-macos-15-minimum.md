# 0010: macOS 15 minimum

- **Date:** 2026-10-02
- **Status:** accepted

## Context
Edge fades use `onScrollGeometryChange` (macOS 15).

## Decision
Package platform `.macOS(.v15)`, LSMinimumSystemVersion 15.0.

## Alternatives considered
Staying on 14 without fades.

## Consequences
The user runs macOS 27, so no impact.
