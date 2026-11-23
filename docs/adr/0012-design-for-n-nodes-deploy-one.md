# 12. Design for N nodes, deploy one, demonstrate two locally

Date: 2026-11-23
Status: Accepted

## Context
OTP's distribution is part of what the project shows, but hosting must stay under about $10 a month. Whether Railway's private network resolves several replicas cleanly enough for clustering is unverified. Dan chose to design for N, deploy one, and demonstrate two locally (decisions log).

## Options considered
1. **Design for N, deploy one, two-node local demo.** Cluster-wide registration, PubSub and the sequence guard are built and tested for several nodes. The demo runs on one node, and the storm and the kill-a-node run use two clustered nodes locally.
2. **Deploy a clustered pair.** It shows distribution live, but it depends on an unverified platform feature and doubles hosting.
3. **Single node only.** The cheapest and simplest, but it gives up the distribution story and leaves the deploy-overlap case untested.

For registration:
1. **`:global`.** Built in, strongly consistent among connected nodes. Slower to register under churn, which doesn't matter at a few nodes.
2. **Horde.** A distributed registry and supervisor using CRDTs. Hands auctions over between nodes, but adds an eventually consistent layer that can briefly allow duplicates.
3. **`:pg` or Syn.** Process groups, not unique names, so a fit for fan-out but not for one owner.

## Decision
Option 1, with `:global` for AuctionServer names. The sequence constraint (ADR 0005) is the guarantee whatever registration does. Local clustering uses libcluster or a fixed node list. Verify current libraries at slice 5. The deploy target and its budget limit are decided at slice 6 with current prices, in a new ADR. Railway Hobby with a hard usage limit is the starting candidate.

## Why
The design pays for distribution where it costs nothing (locally and in CI), and the deployed demo stays cheap and simple. `:global` is the simplest registry that gives one owner per name among connected nodes, and duplicates are already caught by the sequence guard.

## Consequences
- A rolling deploy on one node still overlaps two unclustered containers briefly. That is exactly the case ADR 0005 exists for, and it's tested.
- A two-node deploy stays a stretch goal. It needs a short spike on Railway's private DNS first (decisions log, Q-D2).
- A netsplit between local nodes resolves through `:global`'s conflict handling plus the sequence guard. A test splits and heals two nodes during a storm.
