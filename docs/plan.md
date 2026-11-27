# holdfast-ex: slice plan

One pull request per slice, after the spec (PR #1). Each slice starts in plan mode, and names the invariant, failure mode (spec §7) or acceptance criterion (spec §11) that each new thing exists for. Estimates are in words (build-plan ROADMAP: three to five days in all).

## 1. Foundation and the pure core
- **Proves:** invariants 1, 2, 3 and 5 on paper. For random interleavings and crash points, every log the core can produce satisfies them.
- **What it builds:**
  - A pre-check refusal as recorded events (`bid_placed`, `bid_rejected`), not a bare error.
  - The mix project, with format, Credo, Dialyzer, ExUnit and StreamData. CI with gitleaks.
  - The events (spec §4).
  - `decide/3` and `apply/2`.
  - The bid rules and `minimumNextBid`.
  - The five invariants as functions over an event list.
  - Property tests over random commands, authorization orders and outcomes, times around `ends_at`, repeated keys, and log truncation followed by replay.
- **No:** database, Stripe or processes.
- **Inputs:**
  - Elixir and OTP installed. They aren't installed yet.
  - Current versions checked against releases.
  - Spec §4 and §7.
- **Done when:**
  - The property tests run in CI and pass.
  - A deliberately broken rule (for example, accepting at `ends_at`) is caught and shrunk to a small case, shown in the PR.
  - The generators reach ties, the last second and repeated keys, with counts reported.

## 2. Event store and the auction process
- **Proves:** crash recovery, single-writer safety and "log first" (invariant 6), plus invariant 3's database-time guard.
- **What it builds:**
  - Ecto with Postgres: `auction_events` with the sequence key, `bid_keys`, and the append with an expected seq and the database-time guard for accepts.
  - Replay.
  - AuctionServer under a DynamicSupervisor, with a local Registry for now.
  - The bid call's deadline: the id made before the call, and no `500` on a timeout or a dead server (decisions log, Q-A1).
  - A used key told apart from a sequence conflict.
  - The payments behaviour with the `Memory` adapter.
  - The close timer.
- **Tests:**
  - Kill the server at every step of a bid.
  - A second writer that must lose.
  - Bids straddling `ends_at` with a skewed node clock.
  - In-flight authorizations at close.
- **Inputs:** slice 1's core; Postgres in Docker Compose.
- **Done when:** those tests pass in CI against real Postgres, and the invariant functions run over every resulting log.

## 3. HTTP contract and live updates
- **Proves:** the contract (spec §6), the live path, and acceptance criterion 2's storm on one node.
- **What it builds:**
  - Plug and Bandit, with dev sign-in, sessions and origin checks.
  - Snapshots from ETS.
  - `POST` bid with the deadline and `202`, and the bid poll.
  - SSE with the opening `snapshot` event, `Last-Event-ID` resume from the log, PubSub fan-out and missed-event detection (ADR 0013).
  - Reading one bid's status and listing auctions, designed in this slice's plan (decisions log, Q-A2).
  - Aliases, and rate limits set by configuration.
  - The seed command (spec §10).
  - Holdfast's page built from the pinned commit and served, with page routes falling back to `index.html`.
  - A runner for Holdfast's `storm.ts` from the pinned commit, as is.
- **Inputs:**
  - Holdfast's spec §6, its `load/storm.ts`, and the page's API calls (`web/src`), re-read read-only at the pinned commit.
  - Slice 2.
- **Done when:**
  - The contract tests cover every route and status code the page and the storm use.
  - Two browser tabs on Holdfast's page bid against the in-memory fake locally.
  - The storm passes its own thresholds against one node and the in-memory adapter, and the invariant functions pass over the resulting log.

## 4. Stripe
- **Proves:** invariants 1 and 4 with failure injection, and the gate keeping cancels from starving.
- **What it builds:**
  - The Stripe client over Req and the error taxonomy.
  - The `HttpFake` adapter for Holdfast's shared fake.
  - StripeGate with per-class reserves, its rate and cap set by configuration.
  - HoldKeeper: desired against live holds, cancels, and captures at close.
  - The webhook.
  - Real-Stripe card setup in the contract.
  - The opt-in real test-mode suite, by hand only.
  - Our checker CLI: event log and the fake's `/audit`, through the invariant functions.
  - The storm against one node and the shared fake, and a short one in CI.
- **Inputs:**
  - Holdfast's `server/src/payments/fake-server.ts`, run as a black box.
  - A Stripe test account with `sk_test_` keys (Dan already has one).
- **Done when:**
  - Against the shared fake, with latency, declines, `503`s and failing cancels injected, the storm passes the checker with zero orphaned holds once idle.
  - The Stripe adapter handles a `409` and a replayed `500` from stubbed responses.
  - A flood of bids never delays a cancel past its reserve.
  - The real-mode suite passes by hand.

## 5. Black-box load across two nodes
- **Proves:** behavior under concurrency on a real cluster, and recovery when a node dies. It's not a comparison.
- **What it builds:**
  - Local two-node clustering (libcluster or a fixed node list).
  - `:global` registration replacing the local Registry.
  - A small round-robin proxy, so one storm lands on both nodes.
  - The k6 storm and the checker run against two clustered nodes.
  - A kill-a-node run and a netsplit-and-heal run.
  - The CI storm moved to two nodes.
- **Inputs:** slice 4's storm and checker.
- **Done when:**
  - The storm and the kill and netsplit runs pass the checker.
  - The README gives the throughput in words with its spread.

## 6. Observability and first deploy
- **Proves:** acceptance criteria 1, 5 and 6.
- **What it builds:**
  - `:telemetry` with OpenTelemetry traces across nodes, carried through calls and PubSub.
  - Metrics and alerts, each fired once on purpose.
  - The runbook.
  - A release image.
  - Open demo auctions, from the seed command.
  - **The budget limit first**, then one deployed node and a post-deploy smoke test.
- **Inputs:** the hosting ADR, with current prices checked (ADR 0012), and deployed access settled (decisions log, Q-D1).
- **Done when:** deployed from `main`, the smoke test passes, a trace picture exists, and every alert has fired once.

## 7. Demo polish
- **Proves:** acceptance criteria 1 to 3 on show.
- **What it builds:**
  - The README GIF: two bidders, real test mode, and a node killed mid-storm in the local run.
  - The trace picture and the storm chart.
  - Case-study notes, including how AI was used and where it was wrong.

## Stretch, in Dan's order (to be set)
- Soft close: reschedule the timer and append `auction_extended`.
- A LiveView page. It needs Phoenix and a superseding ADR.
- A two-node deploy, after the Railway private-DNS spike.
