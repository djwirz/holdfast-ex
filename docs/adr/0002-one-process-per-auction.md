# 2. One process per auction is the serializer

Date: 2026-11-23
Status: Accepted

## Context
Bids on one auction must be decided one at a time against the current high (invariant 2). A Stripe authorization takes from a fraction of a second to a few seconds, and nothing may wait on it while holding the right to decide, or one slow card stalls every bidder. Near-simultaneous bids are the normal case at the end of an auction.

## Options considered
1. **A process per auction.** A supervised GenServer owns the auction's state and is the only thing that decides its bids. A bid is a message. The authorization runs in a supervised Task, and its result comes back as a message. Decisions happen in the order results arrive, in memory, with no lock.
2. **A database row lock per decision.** Authorize outside any lock, then lock the auction row, recheck and commit. It works on any stack, but every decision costs a lock round trip, and the ordering lives in the database, not the code.
3. **Optimistic concurrency only.** Any process may decide and append, and conflicts retry. There's no single owner, and contention at the end of an auction turns into retry storms.

## Decision
Option 1. Each open auction has one AuctionServer. A bid call runs the pre-check, appends `bid_placed`, and starts the authorization Task through the gate (ADR 0008). The server never blocks on it. When the result message arrives, the server decides against current state and appends the outcome. The HTTP caller waits up to a short deadline and otherwise returns `202 pending`. The server answers waiting callers with `GenServer.reply` when their bid resolves.

## Why
The process is the critical section, so ordering is the mailbox order, written plainly in one place. Nothing waits on Stripe while holding the right to decide. A crash is contained to one auction and handled by its supervisor (ADR 0003).

## Consequences
- **Commit order is the bid order.** Commit order means the order authorizations come back, so a bidder who clicked first can lose a tie to a faster card. The UI and case study say so.
- **One auction runs on one scheduler at a time.** That's fine at this scale. A very hot auction is bounded by Stripe's limit long before the process.
- **Single ownership must actually hold.** That's ADR 0005 and ADR 0012.
- **Losing bids still spend authorizations.** Pre-checks against in-memory state reject doomed bids first.
- **Long calls.** The deadline reply relies on OTP's handling of late replies to callers that gave up. Verify the current behavior at slice 2.
