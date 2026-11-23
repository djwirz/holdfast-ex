# 8. Stripe's rate limit is a designed constraint

Date: 2026-11-23
Status: Accepted

## Context
Stripe's sandbox allows about 25 requests a second per account, and live mode about 100 ([Stripe rate limits](https://docs.stripe.com/rate-limits)). Each bid costs at least one authorize and usually a later cancel. In a bid storm, authorizations alone can use the whole budget, and cancels and captures, the money-safety work, would starve.

## Options considered
1. **A gate process per node.** A token bucket under that node's share of the limit, plus an in-flight cap. Requests are queued by class, with a reserved share for cancels, captures and hold listing. Bids that wait past the deadline get an honest `202`.
2. **One cluster-wide gate** registered globally. One true count, but it's a single point of failure and a hop for every call, and it's unreachable from an unclustered node during a deploy.
3. **No gate; retry on `429`.** The simplest, but it lets bids starve cancels and turns a storm into a retry storm.

## Decision
Option 1. Each node takes its configured share of the budget (the limit, less a margin, divided by the expected node count), with a fixed reserve for money-safety classes. A `429` from Stripe is a transient error and slows the gate. Pre-checks against in-memory state reject doomed bids before they spend a token.

## Why
Money-safety work can never be starved by bids. The limit is respected by design, with Stripe's `429` as the backstop and not the plan. Per-node gates need no coordination, and they behave the same when a deploy leaves nodes unclustered.

## Consequences
- During a deploy overlap, two nodes may briefly each use a full share. The margin and the `429` handling cover it, and it's measured.
- Throughput under a storm is bounded by the gate. The storm reports it honestly, in words.
- The node count must be configured. A wrong count is a config error that `429`s will show.
