# ADR 0003: Full MIT Open Source

- **Status:** Accepted
- **Date:** 2026-11-16
- **Deciders:** Hangprobe maintainers

## Context

An earlier packaging split kept device watchdogs MIT and the Mac desk core proprietary, with Free / Pro / Team gates. The closed core and license crypto added friction without a durable moat against Instruments, `sample`, and `adb`.

## Decision

1. The entire repository is MIT (`LICENSE`).
2. No paid feature gates — every CLI command and Mac studio feature is free.
3. `oss/` stays a thin device-watchdog + schema subtree for vendoring; it is packaging convenience, not a license wall.
4. Optional future revenue (if any) is distribution or support — not source lockup or runtime entitlements.

## Consequences

One license story, one repo, agents and CI get every command. Compete on taste, docs, and install quality.
