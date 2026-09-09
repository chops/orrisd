---
status: accepted
date: 2026-09-04
---

# ADR-0002: Contain read-only capture failures

## Context

Pane owners could terminate on a five-second `AiPair.Tmux` capture call
timeout. Repeated failures can exhaust supervisor restart budgets
and discard in-memory registration and queued messages. A transient error tuple
also previously retained an idle verdict, allowing delivery without a readable
pane.

## Decision

Only the read-only capture call uses a one-second caller deadline and converts
GenServer timeout and missing-backend exits into static error maps (status 124
and 125 respectively). Neither means `pane_gone`. Mutating calls are unchanged
and are never automatically retried by this change.

A transient capture error moves the pane to `unknown`, invalidates idle
debounce, and preserves the existing owner and pending queue. Recovery requires
two matching classified captures. Busy output may change between them because
busy never authorizes delivery; idle recovery still requires identical
stripped-content fingerprints, then the normal idle debounce before sending.
Existing IPC shapes are unchanged.

The pinned OTP 28 toolchain exceeds the OTP 24 alias floor: late replies after
GenServer call timeout are dropped. A test explicitly checks this assumption.

## Limits and Followups

- The shared tmux GenServer still serializes operations. The caller deadline
  does not cancel work already queued there or remove head-of-line blocking.
- Status still waits on the pane process. Its timeout classification needs a
  separate truthful IPC contract change; this design does not promise instant
  snapshots or a general deadline for status under mutating operations.
- Registration and queue survival across an actual owner crash are not solved.
  Containment prevents the observed timeout crash, not all possible crashes.
- A missing tmux pane retains the existing dead-pane reaper policy.

## Verification and Rollback

Tests reproduce uncaught capture timeout and missing-backend exits before the
fix, stale-idle eligibility, and premature recovery with slow polling. Tests
also cover the real capture boundary through the pane owner, preservation of
queued sends, debounce cancellation, and recovery without duplicate delivery.
Run the canonical `nix develop --impure --command bin/verify` gate.

Operators explicitly choose when to deploy a new package. Rollback is restoring the prior package, with its known
capture-timeout failure mode; no durable format migration is introduced.
