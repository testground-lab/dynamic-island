# 0007: Interaction model

- **Date:** 2026-10-02
- **Status:** accepted

## Context
Requirement 04 (copy Vorssaint's interactions).

## Decision
Click opens and pins (takes key focus only then; Esc, click outside, another app activating, or the header's camera area close). Optional 'Open on hover' (0.25 s open, 0.18 s close on exit). Hover only nudges the idle notch. Two-finger swipe down on the notch opens; swipe up closes only when it starts on the header row; scrolling content never closes. Since requirement 16, a precise sideways stroke (>= 50 pt, within 30° of horizontal) on the open island switches pages and never opens or closes. Springs: open 0.42 s/bounce 0.22, close 0.28 s/no bounce; Reduce Motion respected. Logic is a tested state machine.

## Alternatives considered
Hover-to-open default (earlier version), sideways page swipe (removed with requirement 07, back with requirement 16).

## Consequences
Real-trackpad behaviour still needs on-screen checking.
