# 7. Time is part of the state machine

Date: 2026-11-23
Status: Accepted

## Context
No bid may be accepted at or after `ends_at` (invariant 3). The node's clock and the database's can disagree, and two nodes can disagree with each other. A separate close job that polls is one more moving part racing the bid flow.

## Options considered
1. **The server schedules its own close** with `Process.send_after`. Close is an event in the log. `decide` compares `now` to `ends_at` as a strict check. The append of a `bid_accepted` is also guarded by database time, so a skewed node clock can't accept late.
2. **A close job** that marks auctions closed on an interval. Independent of the servers, but it races them, and it adds coordination.
3. **Trust the node clock only.** The simplest, but clock skew between nodes, or between a node and the database, would let a late bid in.

## Decision
Option 1. The timer closes the auction in normal running. `decide` refuses late bids by the clock it's given. The database-time guard on accepting appends is the backstop: the insert carries `ends_at` and is refused if database `now()` is at or past it. Soft close, if built, reschedules the timer and appends `auction_extended`.

## Why
"Nothing is accepted after close" holds by construction in the log, and by database time at the moment of commit. That's the same reference the checker uses.

## Consequences
- A restarted server reschedules its close from the replayed `ends_at`, or closes at once if the time has passed.
- The guard puts a little logic in the append. It's tested with bids straddling `ends_at` and a skewed node clock.
- Verify the exact Ecto/SQL shape of a guarded insert at slice 2.
