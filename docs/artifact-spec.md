# Artifact spec: holdfast-ex

Filled from the kit's `templates/artifact-spec.md` before any agent builds code. Draft for PR #1, 2026-11-23.

## One line
Real-time auctions in Elixir where a bid counts only once a Stripe test-mode hold covers it. Each auction is one supervised process that rebuilds itself from an append-only event log, so ordering and crash recovery come from how the system is shaped, not from locks and repair jobs.

## What it exercises
**Elixir and OTP (processes, supervision, registries, ETS, distribution), event sourcing on PostgreSQL, property-based testing, Stripe's authorize-and-capture model, rate limiting, SSE fan-out**, plus testing, CI and observability.
This list comes out of the design. It isn't a target the design was built to hit. Each item is there because the problem needs it. A single owner per auction is what orders bids. A log the owner replays is what makes a crash a restart and not a repair. Holds that follow from the state are what keep cards clean. And Stripe's rate limit is the real ceiling under a bid storm. No skills score gates any slice, and a tool is never added just to show it off (CLAUDE.md).

## Problem and users
- **Who has the problem:** anyone running timed auctions with real money: marketplaces, charity auctions, ticket drops. Also the engineers who must show that the winner can pay and that no card is left with a stray hold.
- **What they do today:** charge at close and chase declines. Or hold per bid, then add locks, an outbox, a reconciler and a pub/sub service to keep it all correct. That's how Holdfast does it.
- **Why it matters:**
  - A lost bid or an unpaid winner breaks trust in the auction.
  - An orphaned hold is money stuck on a customer's card.
  - The supporting machinery is where those bugs hide.

  This project asks whether a runtime built around isolated, supervised processes lets the same guarantees come with less of that machinery.

## Scope
- **Must have:**
  - One supervised process per auction that orders every decision (ADR 0002).
  - An append-only event log that is the source of truth and the source of recovery (ADR 0003).
  - A pure `decide` / `apply` core, with the invariants as functions and property tests over random interleavings and crash points (ADR 0004).
  - Single-writer safety from a sequence constraint, across crashes and deploys (ADR 0005).
  - Holds derived from state, kept true by one loop (ADR 0006).
  - Close scheduled inside the state machine (ADR 0007).
  - A Stripe gate under the account's rate limit, with room kept for cancels and captures (ADR 0008).
  - Reads from ETS and fan-out over PubSub, with no Redis (ADR 0009).
  - Holdfast's HTTP and SSE contract, so Holdfast's page and load test run against it unchanged (ADR 0011).
  - Deployed on one node with a budget limit, and shown clustered on two nodes locally (ADR 0012).
  - Tests and CI, traces, metrics, alerts and a runbook.
- **Nice to have:**
  - Soft close (anti-sniping) by rescheduling the close timer.
  - A LiveView page. It would need Phoenix, and a superseding ADR (ADR 0010).
  - A two-node deploy, if Railway's private network supports clustering (decisions log).
- **Non-goals (on purpose):**
  - Any benchmark against Holdfast, or tuning meant to win one. That's the last stage of `bid-storm`, a separate project.
  - Changes to the Holdfast repo. It's read-only from here.
  - Real money. Stripe test mode only.
  - Sharding, multi-region, proxy bidding, seller payouts.

## Success metric
- **Correct:** the property tests and the k6 storm (through two clustered local nodes, with Stripe failures injected) show zero invariant violations.
- **Recovers:** killing an auction process or a node at any step loses no accepted bid and leaves no orphaned hold once idle.
- **Honest throughput:** the storm reports what the system does under Stripe's sandbox limit, in words with its spread. It isn't a comparison.
- **Cost:** hosting stays under about $10 a month, with a hard limit set before the first deploy.

## Constraints
- **Time:** three to five days of focused sessions (build-plan ROADMAP). Elixir and OTP are new ground.
- **Budget:** under about $10 a month. A hard limit and an alert exist before anything is deployed.
- **Data:** synthetic users and auctions only. Stripe test mode only (`sk_test_` keys).
- **Privacy:** no employer details. The case study stands on the project alone.
- **Independence:** no design choice may be justified by how Holdfast does it. The only shared things are the contract, the Stripe fake and the k6 storm, all used as black boxes.

## Quality plan
- **Tests:**
  - Unit and property tests (StreamData) on the pure core: random command interleavings, random crash points (truncate the log, replay, check), and the invariants as functions over event lists.
  - Integration tests against real Postgres: the append with the sequence constraint, a second writer that must lose, replay, and processes killed at every step.
  - Contract tests over HTTP and SSE, matching Holdfast's spec §6.
  - Payments tests against an in-memory fake, Holdfast's shared HTTP fake, and an opt-in real test-mode suite.
  - Holdfast's k6 storm as the black-box load test, plus our own checker.
- **Evals:** no AI features.
- **Observability:**
  - `:telemetry` events with OpenTelemetry traces from request through the auction process, Stripe and the fan-out.
  - Metrics on bid outcomes, gate queue time, holds that should not exist, and replay time.
  - Alerts and a runbook.
- **Accessibility and performance:** the page is Holdfast's, served unchanged. Performance is measured, not promised.
- **Security basics:**
  - Secrets in the host's secret store.
  - Every request body validated.
  - Session cookies and origin checks as in the contract.
  - Production refuses non-test Stripe keys.
  - gitleaks in CI.
- **CI/CD:** every PR runs format, compile with warnings as errors, Credo, Dialyzer, the unit, property and integration tests, the contract tests, a short storm with the checker, and gitleaks. Deploys happen only from `main`.

## Depth target
Current rung: 0 · Target rung: 3 (engineered)

## Build stack (in order)
1. Elixir and OTP, versions checked against current releases at slice 1 (ADR 0010).
2. Plug and Bandit for HTTP and SSE; `phoenix_pubsub` for fan-out; Ecto on PostgreSQL for the event log (ADRs 0003, 0009, 0010).
3. StreamData for property tests (ADR 0004).
4. Our own thin Stripe client over Req, behind a payments behaviour with fake adapters (ADRs 0008, 0010).
5. `:telemetry` and OpenTelemetry; Railway for the one deployed node (ADR 0012, hosting checked at slice 6).
