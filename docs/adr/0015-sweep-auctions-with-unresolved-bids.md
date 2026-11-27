# 15. The sweep also covers auctions with an unresolved bid

Date: 2026-11-27
Status: Accepted

Supersedes the definition of "unfinished" in ADR 0014. The rest of ADR 0014 stands.

## Context
ADR 0014 calls an auction unfinished while it isn't closed, or its winner isn't captured. So an auction that closed with no winner is finished. A bid can still be in flight at that close. If the node dies then, nothing restarts the auction: the bid stays `pending` for good, and a hold the provider placed for it has no outcome in the log (invariant 4, and spec §7 "node dies").

## Options considered
1. **Unfinished also means any bid without an outcome.** The sweep restarts the auction, which asks again with the same bid id and decides the bid as lost.
2. **Leave it to HoldKeeper (slice 4)** to cancel the hold. The money is freed, but the bid still reads `pending`, and HoldKeeper's rule is to leave pending bids' holds alone.
3. **Wait for a request** (a retry or a poll) to start the server. Nothing guarantees one comes.

## Decision
Option 1. The sweep keeps a server for every auction that is not closed, or is closed with a winner not yet captured, or has a `bid_placed` with no `bid_accepted`, `bid_rejected` or `bid_lost`.

## Why
Every bid that was written gets an outcome, with no request needed, through the same replay path as any other restart.

## Consequences
- A bid gets at most one outcome (invariant 5), so the sweep can compare the two counts per auction.
- The sweep reads every auction's events on each pass. That's fine at demo scale, and is revisited if it's measured as slow.
