# holdfast-ex: decisions log

Questions from the planning handoff (2026-11-23) and from writing the spec. A decision that's expensive to reverse also has an ADR; this log links them. Newest additions go at the bottom of each table.

## Resolved
| # | Question | Answer | Why | Who | ADR |
|---|---|---|---|---|---|
| Q1 | Framework: Phoenix, or Plug + Bandit + `phoenix_pubsub` + Ecto | Plug + Bandit | Only what the contract needs. LiveView later would add Phoenix | Dan | 0010 |
| Q2 | Client: Holdfast's React page or a LiveView page | Holdfast's page against the same contract first; LiveView as a later milestone | A real page at little cost, and the contract proven by a client not written for this server | Dan | 0011 |
| Q3 | Nodes: one deployed, or a clustered pair | Design for N, deploy one, demonstrate two clustered locally | Distribution shown where it's free, with a cheap and simple demo | Dan | 0012 |
| Q4 | Where the code lives | `~/projects/holdfast-ex`, its own repo | build-plan's rule: each project is a standalone repo directly under `~/projects/` | build-plan CLAUDE.md | |
| Q5 | How the existing checker is satisfied | Our own checker, applying the core's invariant functions to the event log and the fake's `GET /audit`. No projection into `bids` and `auctions` | Holdfast's checker also reads its `outbox` and `users` tables and its own Payments port (`server/src/check-invariants.ts`), so a projection would mean imitating Holdfast's internals. A checker that works only through the contract is `holdfast-bench`'s job | planner | 0004 |
| Q6 | Stripe client: a community library or our own | Our own thin client over Req, with an error taxonomy | Exact control over idempotency keys and the `409` and replayed-`500` cases the invariants depend on | planner | 0010 |
| Q7 | Auth | Dev sign-in route and session cookie, as in the contract. Real sign-in only if Dan asks | It's what the storm and the page use. Deployed access is Q-D1 | planner | |
| Q8 | In-flight authorizations when an auction closes | They resolve as `bid_lost` (reason `ended`), and HoldKeeper cancels their holds | One mechanism for every stray hold | planner | 0006, 0007 |
| Q9 | Replay cost for long auctions | No snapshots at demo scale. Replay time is a metric, revisited only if it's measured as a problem | Auctions last at most a day | planner | 0003 |
| Q10 | The rate gate: per node or cluster-wide | Per node, with a configured share and a reserve for cancels and captures. Stripe's `429` is the backstop | No coordination, and the same behavior when a deploy leaves nodes unclustered | planner | 0008 |
| Q11 | Registry | `:global`, with the sequence constraint as the guarantee | Unique names among connected nodes, built in. Horde's eventual consistency adds nothing the guard needs | planner | 0012 |
| Q12 | Do the contract's versions have to be contiguous | No. They must increase. Event seqs have gaps | Holdfast's page ignores anything at or below the version it has (`web/src/live.ts`). The spec notes this for `holdfast-bench` | planner | 0003 |
| Q13 | Closed is closed against node clock skew | The accept append is guarded by database time | Same reference as the checker; a skewed node can't accept late | planner | 0007 |
| Q14 | Roadmap placement | Phase 5b, after Coverage Check and before portfolio polish | No preference given; the planner's recommendation | planner | |
| Q15 | Where the comparison lives (`holdfast-bench` in Q5, Q12 and ADRs 0003 and 0011) | The last stage of [bid-storm](https://github.com/djwirz/bid-storm). No `holdfast-bench` repo | One repo already records storms from outside | Dan, 2026-11-26 | |
| Q-R2 | How Holdfast's page and storm are pinned and fetched | Commit `427109f8813b6f72a7bb0b8bd42b6033bf250756`, cloned read-only in CI and by a local script. A bump is a reviewed PR | The latest Holdfast code the contract was re-read at | planner | 0011 |
| Q16 | A bid the pre-check refuses: recorded, or only answered | Recorded as `bid_placed` and `bid_rejected` with its key | The contract gives every bid an id, a poll route and idempotency | planner | |
| Q17 | Missed live events, when seqs have gaps | Each published event carries the previous public seq | A gap in seqs is normal, so it can't signal a loss | planner | 0013 |
| Q18 | When the k6 storm first runs | Slice 3 on one node, slice 4 with the shared fake and the checker, slice 5 on two nodes | Slice 4 already needed a storm to be done, and contract problems show up sooner | planner | |

## Still open
| # | Question | Leaning | Who answers | By |
|---|---|---|---|---|
| Q-D1 | Deployed access. Holdfast refuses dev sign-in in production, but its page needs a way to sign in. Open dev sign-in with rate limits and a passcode fallback, or GitHub OAuth like Holdfast? | Dev sign-in behind a passcode, with rate limits. It's test mode, and it keeps the contract's route | Dan | slice 6 |
| Q-D2 | Does Railway's private network resolve several replicas cleanly for clustering? | Unverified. Time-box a spike before a two-node deploy | planner, spike | stretch |
| Q-D3 | Hosting and its budget limit, with current prices | Railway Hobby with a hard usage limit, the starting candidate | planner, then Dan | slice 6 (ADR) |
| Q-R1 | Stretch order: soft close, LiveView page, two-node deploy | Soft close first (smallest), then LiveView | Dan | after slice 7 |
| Q-V1 | Current Elixir, OTP, Bandit, Plug, Ecto, Postgrex, `phoenix_pubsub`, StreamData, Req, OpenTelemetry and libcluster versions and APIs | Check at the slice that first uses each one. Never from the handoff or this repo's docs | planner | each slice |
| Q-V2 | OTP's handling of a late `GenServer.reply` to a caller that timed out | Verify current behavior | planner | slice 2 |
| Q-A1 | What the HTTP layer answers when the call times out or the server dies before it can tell whether `bid_placed` committed. A `202` for a bid that was never written would poll as `404` | Check the log by bid id; if absent, retry the command, which the key makes safe | planner | slice 2 |
| Q-A2 | How `GET /api/bids/:id` and `GET /api/auctions` read, with no projections, on any node and after close | Fold from the log, indexed by bid id; revisit if measured as slow | planner | slice 3 |
| Q-B1 | When the comparison method is written, and how its rate-limited condition works | In bid-storm, before slice 5 gives this system any load results | Dan | slice 5 |
