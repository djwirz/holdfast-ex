# 5. Single writer enforced by a sequence constraint, not a lock

Date: 2026-11-23
Status: Accepted

## Context
ADR 0002 assumes one AuctionServer per auction. That can fail:
- during a rolling deploy, when the old and new containers overlap and aren't clustered;
- during a netsplit;
- when registration races.

Two writers deciding the same auction could both accept a bid. This is the project's biggest technical risk.

## Options considered
1. **Expected sequence numbers under `PRIMARY KEY (auction_id, seq)`.** Each append says which seq it expects to write next. A second writer's insert conflicts, and that server crashes and replays.
2. **A database lock** (row lock or advisory lock) held for each decision, or for the server's lifetime. Strong, but a lock held for a lifetime outlives dead connections badly. A per-decision lock is what option 1 avoids.
3. **Trust the registry alone.** Cluster-wide registration (ADR 0012) prevents most duplicates. But it can't see an unclustered overlap during a deploy, and it can't resolve a netsplit safely.

## Decision
Option 1, with the registry as the first line and the constraint as the backstop. One insert per append, no lock wait. State changes in memory only after the append commits (spec §4, "log first").

## Why
It is the same safety job as a lock: at most one writer's decision lands for any seq. It costs nothing on the happy path, and it holds whatever the registry or deploy does.

## Consequences
- **A losing writer may have placed holds.** It started authorizations before it found out it lost. HoldKeeper cancels them (ADR 0006), and invariant 4 is checked after second-writer tests.
- **A losing writer may have told a caller "accepted"** if it replied before appending. That's forbidden: replies come only after the append commits. A test runs a second writer and kills the server at every step.
- **Deploys cause a brief burst of crashes and replays** while old and new overlap. That's acceptable, and it's measured.
