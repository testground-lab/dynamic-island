# 0008: Vorssaint is GPL-3.0: reimplement, don't copy

- **Date:** 2026-10-02
- **Status:** accepted

## Context
This project has no license; Vorssaint's island is GPL-3.0.

## Decision
Study behaviour and design, write our own code. Reviews flag near-verbatim code; the gesture recogniser and chart selection style were rewritten after review.

## Alternatives considered
Copying source (license conflict).

## Consequences
Some numbers (delays, spring timings, 480 pt width, 44 pt wings) match theirs as design facts.
