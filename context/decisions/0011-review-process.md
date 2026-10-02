# 0011: Review process

- **Date:** 2026-10-02
- **Status:** accepted

## Context
~/.claude/CLAUDE.md model policy.

## Decision
Each round: internal review by a Claude that didn't write the code (opus; fable for the Keychain/networking part), then a final sol review; fix findings. If the GPT gateway rate-limits (429), the sol review is noted as owed.

## Alternatives considered
Single review.

## Consequences
Several real bugs were caught this way (fixed height not enforced at runtime, overage header marking accounts limited).
