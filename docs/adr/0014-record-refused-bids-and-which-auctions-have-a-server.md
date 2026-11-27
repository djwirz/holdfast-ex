# 14. Record refused bids, and which auctions have a server

Date: 2026-11-27
Status: Accepted. What "unfinished" means superseded by 15

Supersedes the sentence in ADR 0002 that gives one AuctionServer to each open auction. The rest of ADR 0002 stands.

## Context
The contract gives every bid an id, a poll route and idempotency, including one the pre-check refuses and one that arrives after the close. So a refusal has to be stored, and a closed auction needs its single writer back to store it. Separately, a server that starts only when a bid arrives leaves two holes: an auction nobody bids on gets no close timer, and a snapshot read on a node that has no copy has nobody to ask.

## Options considered
**A refused bid:**
1. **Events in the auction's log:** `bid_placed` and `bid_rejected`, with the `bid_keys` row.
2. **Only a row in `bid_keys`,** carrying the outcome. The log stays smaller, but a bid's state then has two sources.
3. **Answer without storing.** A retry could get a different answer, and a changed amount on the key would not be refused.

**Which auctions have a server:**
1. **Every unfinished auction, kept up by a sweep, and any other on demand.**
2. **Only on demand.** Nothing closes an auction that gets no traffic.
3. **Every auction, always.** Simple, but processes pile up for auctions that are over.

## Decision
Option 1 for both.
- A refusal by the pre-check appends `bid_placed` and `bid_rejected` together, and calls nobody.
- **Unfinished** means not closed, or closed with a winner whose capture hasn't succeeded. A sweep, at node start and on an interval, finds these in the log and starts any server that isn't running. It only starts servers: the server still decides the close (ADR 0007).
- **On demand:** a bid, or a snapshot read that finds no copy, starts the server of any auction that exists. An unknown id starts nothing.
- A finished auction's server stops after an idle period with no bid pending. Its ETS snapshot stays.

## Why
The log stays the only source of a bid's state, and one writer decides every event, whenever it arrives. A seeded or orphaned auction closes without waiting for a visitor.

## Consequences
- The log grows with refused bids, including late ones. Rate limits bound it, and replay time is already a metric (ADR 0003).
- Private events can follow `auction_closed`, so an auction's version can pass the id of its close event.
- A refusal is an append, so two writers for one auction conflict more often. Restart limits have to allow for it.
- The first read of a finished auction on a node costs a replay.
