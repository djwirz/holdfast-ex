# 3. An append-only event log is the state

Date: 2026-11-23
Status: Accepted

## Context
A process that owns state in memory loses it when it crashes. Recovery must not depend on a separate repair job reading half-finished rows. The SSE stream needs every public change in order, resumable by id. The invariants must be checkable after the fact.

## Options considered
1. **An event log.** One `auction_events` table of typed events, keyed by `(auction_id, seq)`. The process rebuilds by replaying its events. The seq is the auction version and the SSE event id.
2. **Current-state tables** (auctions, bids) that the process updates, with the process holding a cache. Familiar and easy to query, but recovery means reconciling the cache with rows written mid-flow. The history behind the state is lost, or needs a second table anyway.
3. **Both: events plus projections in the same transaction.** Queryable and replayable, but two representations to keep in step from day one.

## Decision
Option 1. Events are the only source of truth. Replay rebuilds a server. `seq` is the version and the SSE id, and resume reads the same table. Idempotency keys get their own `bid_keys` table with `UNIQUE (user_id, idempotency_key)`, written in the transaction that appends `bid_placed`. Users, sessions and webhook dedupe are plain tables, because they aren't auction state. No projections in v1: snapshots are kept in memory and ETS (ADR 0009).

## Why
Crash recovery becomes a supervisor restart. The invariants become functions over an event list, the same in tests and in the checker (ADR 0004). The SSE resume needs no extra table.

## Consequences
- Queries across auctions (a list page, an admin view) fold events or use a small read model later.
- Versions have gaps, because private events take seqs too. Holdfast's page only needs versions that increase (spec §6), and the contract notes it for `holdfast-bench`.
- Replay time grows with auction length. At demo scale (at most a day, a few thousand events) there are no snapshots. Replay time is a metric, and snapshotting is revisited only if it's measured as a problem.
- Event schemas need versioning once data exists. Each event carries a type and a schema version from the start.
