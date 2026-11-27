# 16. One supervisor per auction, so restart limits are per auction

Date: 2026-11-27
Status: Accepted

## Context
A writer that loses a seq crashes and replays (ADR 0005), and refusals are appends too, so conflicts can come in bursts (ADR 0014). A supervisor counts restarts across all of its children and gives up when there are too many. With every AuctionServer directly under one DynamicSupervisor, one auction in a crash loop would take down all of them.

## Options considered
1. **A small supervisor for each auction,** `temporary` under the DynamicSupervisor, with the server as its one `transient`, `significant` child. Each auction has its own restart count.
2. **One DynamicSupervisor with a very high restart limit.** No extra processes, but the limit is still shared, and a high one hides a real crash loop.
3. **`temporary` servers, restarted only by the sweep.** Nothing is shared, but a crash then waits for the next sweep or request instead of being a supervisor restart.

## Decision
Option 1. Ten restarts in five seconds are allowed per auction. Past that, that auction's supervisor gives up and exits, and the sweep or the next bid starts it again. A server that stops normally closes its supervisor too (`auto_shutdown: :any_significant`).

## Why
A crash is still a supervisor restart (ADR 0003), and the damage a bad auction can do stops at that auction.

## Consequences
- Two processes per running auction instead of one. At this scale that costs next to nothing.
- An auction that always crashes is retried by every sweep. It shows in the logs, and slice 6 should alert on it.
