# 9. Reads never touch the process; fan-out over PubSub, no Redis

Date: 2026-11-23
Status: Accepted. Gap detection superseded by 13

## Context
Page loads and snapshot polls far outnumber bids. If every read called the AuctionServer, reads would queue behind decisions in its mailbox. Live updates must reach SSE connections on every node, in order, resumable by `Last-Event-ID`, without inventing or dropping an event.

## Options considered
1. **ETS snapshots plus `Phoenix.PubSub`.** The server writes its public snapshot to a node-local ETS table on every change, and publishes public events on PubSub. GETs read ETS. SSE connections read the log for resume, then follow PubSub, deduplicating by seq.
2. **Reads from the database.** Always consistent with the log, but every page load folds events or needs projections.
3. **Redis pub/sub and a cache.** The usual cross-instance answer, but a separate service for something the runtime provides between connected nodes.

## Decision
Option 1. One ETS table per node, written by the owning server on its node and refreshed on others from PubSub. PubSub is a doorbell plus the event itself. The log is the truth: a connection that sees a seq gap, or hears nothing for a while, reads the gap from `auction_events`.

## Why
Reads scale with ETS, not with one process's mailbox. Distribution between clustered nodes is built in, which removes Redis. Because the log is the source, a lost or duplicate PubSub message can only delay an update, never reorder or invent one.

## Consequences
- An unclustered node, as during a deploy overlap, misses PubSub. Its connections fall back to the log poll until the cluster forms.
- A snapshot on a non-owner node can lag by a message. The bid path never reads ETS, so the lag only affects display.
- Verify `phoenix_pubsub`'s current standalone use without Phoenix at slice 3.
