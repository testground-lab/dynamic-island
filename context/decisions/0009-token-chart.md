# 0009: Token chart with Swift Charts

- **Date:** 2026-10-02
- **Status:** accepted

## Context
Requirement 10.

## Decision
Swift Charts bars: hourly for Today (calendar hours, DST-safe), daily for 7d/30d, stacked by provider colour; partial periods lighter; pre-tracking shaded "not recorded"; legend top 3 + "+N"; 24-hour tick labels; hover outlines the period with a readout; VoiceOver summary. Chart logic lives in tested `ChartLayout`.

## Alternatives considered
Custom GeometryReader bars (Vorssaint's approach).

## Consequences
Hover readout on the non-key panel still to be verified on screen.
