# 13. Detect missed events by the previous public seq

Date: 2026-11-27
Status: Accepted

Supersedes the gap detection in ADR 0009. The rest of ADR 0009 stands.

## Context
ADR 0009 says an SSE connection that sees a seq gap reads the gap from `auction_events`. ADR 0003 gives private events seqs too, so public events have gaps between them in normal running. A gap says nothing: either every public event triggers a log read, or a connection treats gaps as normal and misses a lost message.

## Options considered
1. **Each published event carries the previous public event's seq.** The auction's state tracks the seq of its latest public event. A connection compares that with the last version it has. The number travels between nodes only; SSE clients never see it.
2. **Read the log on every public event.** PubSub becomes only a doorbell. Nothing can be missed, but each accepted bid costs a read per connection, or a shared reader per node.
3. **A second, contiguous version for public events.** Gaps become meaningful again, but the log gains a second numbering to keep consistent, and the SSE id and the snapshot version have to change with it.

## Decision
Option 1. A connection holds `last`, the version it has: the snapshot's version, the client's `Last-Event-ID`, or the id of the latest event it sent. For a published event with seq `id` and previous public seq `prev`:
- `id <= last`: a duplicate, dropped;
- `prev > last`: something was missed, so the connection reads the public events after `last` from the log and sends those;
- otherwise it sends the event.

`prev` is 0 for the first public event. A connection subscribes before it reads the snapshot or the log, buffers what arrives meanwhile, and reads the log once more after the snapshot, since a node's ETS copy may be behind. The slow poll of the log stays, for a lost message that nothing follows.

## Why
A missed message is seen as soon as the next one arrives, with no read in the normal case and no change to the contract or the log's numbering.

## Consequences
- The previous public seq is part of the state `apply` rebuilds, so it survives a restart. Property tests cover it.
- `prev` may be at or below `last` without being equal to it (a snapshot's version can be a private event's seq). That is not a gap.
- A lost final event, such as `auction.closed`, is found only by the slow poll.
