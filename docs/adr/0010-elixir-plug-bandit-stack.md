# 10. Stack: Elixir/OTP, Plug + Bandit, Ecto, phoenix_pubsub, our own Stripe client over Req

Date: 2026-11-23
Status: Accepted

## Context
The service needs HTTP and SSE serving the contract (spec §6), Postgres access for the event log, cross-node pub/sub, a Stripe client with a precise error taxonomy, property tests, and telemetry. Dan chose Plug + Bandit over Phoenix (decisions log), and LiveView is a later stretch.

## Options considered
1. **Plug + Bandit + `phoenix_pubsub` + Ecto.** Only what the contract needs, with every route and the SSE loop written plainly.
2. **Phoenix.** Router, Endpoint, Channels and LiveView, with generators. A shorter path to LiveView, but most of it goes unused by a JSON + SSE contract.
3. **For Stripe:** a community Elixir library, or our own thin client over Req. A library covers the whole API, but the project uses a handful of PaymentIntent calls and needs exact control over idempotency keys, retries and the mapping of `409` and replayed `500`s.

## Decision
- Elixir and OTP, versions checked against current releases at slice 1 and never taken from this doc.
- Plug with Bandit for HTTP and SSE.
- `phoenix_pubsub` standalone.
- Ecto with Postgrex for the event log.
- StreamData for property tests.
- Our own Stripe client over Req, about a page of code, behind a payments behaviour with `Stripe`, `HttpFake` and `Memory` adapters.
- `:telemetry` with OpenTelemetry.
- Credo and Dialyzer in CI.

## Why
A small surface that is all load-bearing, which suits a project meant to show how OTP does the heavy lifting. Owning the Stripe client keeps the error taxonomy, which the invariants depend on, in reviewable code.

## Consequences
- More hand-written HTTP plumbing than Phoenix would need (sessions, origin checks, SSE). It's small and covered by the contract tests.
- A LiveView page later means adding Phoenix. A new ADR would supersede the framework part of this one.
- The Stripe client must track Stripe's API version. It pins one, and the opt-in real test-mode suite catches drift.
