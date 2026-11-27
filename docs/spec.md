# holdfast-ex: spec

Status: Accepted in PR #1, revised 2026-11-27 · Date: 2026-11-23 · Owner: Dan

## 1. Problem

Timed auctions with real money need two things to be true at once: the highest bid wins, and the winner can pay. The usual failures:
- **Unpaid winners:** the card is charged at close and declines.
- **Lost bids:** two near-simultaneous bids both read "current high is X" and both count.
- **Orphaned holds:** money authorized for a bid that later lost, and never released.

The known fix is to place a Stripe authorization hold for every bid before it counts, and release holds that stop mattering. That fix needs three things to be true:
- **One ordering:** something has to order bids on an auction.
- **Recovery:** a crash between "Stripe said yes" and "we recorded it" has to be recoverable.
- **No stray holds:** some process has to make sure every hold that shouldn't exist gets canceled.

holdfast-ex builds this in Elixir/OTP, designed from the problem up:
- **One process per auction.** Each auction is a supervised process. It owns the auction's state, receives bids as messages, and is the only thing that decides them.
- **An append-only event log.** The log in PostgreSQL is the state. The process rebuilds itself by replaying the log, so a crash is a supervisor restart, not a repair job.
- **Holds derived from state.** Which holds should exist follows from the state. One loop cancels the rest.
- **Stripe's rate limit as a constraint.** Stripe's sandbox limit is about 25 requests a second per account ([Stripe rate limits](https://docs.stripe.com/rate-limits)). It's treated as part of the design, not an error to retry around.

**What a viewer sees.**
1. Two browser windows on one auction, bidding against each other. The price updates in both within about a second.
2. The Stripe dashboard (test mode) shows one hold per bid, each canceled when it's outbid, and the winner's captured at close.
3. A node is killed mid-storm. Its auctions come back on restart by replaying their logs, and no accepted bid is lost.
4. The storm's checker: zero violations. The property tests' count of random interleavings and crash points, all passing.
5. One bid's trace, from the request through the auction process, the Stripe gate and Stripe, to the SSE write.

That sequence is the README GIF and the case study.

### Why this is worth building (portfolio framing)
It shows Elixir and OTP used for what they're for: processes as the unit of consistency, supervision as recovery, ETS for reads, distribution for a cluster. It also shows event sourcing on PostgreSQL with a real single-writer guarantee, property-based testing as the main correctness evidence, and Stripe's authorize-and-capture model under a hard rate limit. It's judged on its own merits. It draws only on public patterns for hold-backed bidding and on Holdfast's public contract.

## 2. Non-goals (v1)

- **Comparison.** No benchmark against Holdfast, and no tuning meant to win one. That's the last stage of [bid-storm](https://github.com/djwirz/bid-storm), a separate project (§12).
- **Changes to Holdfast.** Its repo is read-only from here.
- **Real money.** Stripe test mode only, with no live-mode code path.
- **Proxy bidding, seller payouts, 3-D Secure challenges at bid time, multi-currency.**
- **Auctions longer than a day.** Card holds are short-lived, and creation refuses anything over a day.
- **Sharding and multi-region.** v1 is designed for a few nodes, not many.
- **Real sign-in in v1.** Dev sign-in as in the contract. Deployed access is an open question (decisions log, Q-D1).

## 3. Appetite

- **Time:** three to five days of focused sessions (build-plan ROADMAP, pace as of 2026-11-23). Elixir and OTP are new, and the single-writer work in slice 2 is where the time goes.
- **Money:** under about $10 a month for hosting, with a hard limit and an email alert set before the first deploy. Stripe test mode is free.
- **Shape:** seven thin PRs after this one, local-first. The first five never deploy. See [plan.md](plan.md).
- **If time runs short, cut in this order.** The project exists to prove three things: every accepted bid is covered by a hold, a crash at any step loses nothing and leaks nothing, and it's live and traceable. Cut what proves none of those first:
  1. Soft close.
  2. Serving Holdfast's page. The contract tests and the storm still run without it.
  3. The two-node local demo. The design for N nodes stays, and the sequence guard still covers deploys.

  **Never cut:**
  - The property tests with crash points.
  - The sequence constraint and the second-writer test.
  - The hold loop.
  - The Stripe gate's reserve for cancels and captures.
  - The k6 storm with the checker.
  - The trace.
  - The budget limit.

## 4. Architecture

```
 client (Holdfast's React page, k6, tests)       node (Elixir/OTP, Plug + Bandit)                       external
 ─────────────────────────────────────────       ──────────────────────────────────                     ────────
 POST /api/auctions/:id/bids ──────────────▶ Plug router ── GenServer.call(deadline) ──┐
 GET  /api/bids/:id                                                                     ▼
 GET  /api/auctions/:id  ◀── ETS snapshot ◀───────────────────────────── AuctionServer (one per auction,
 GET  /api/auctions/:id/events (SSE) ◀── PubSub ◀────────── publish ───   via a cluster-wide registry)
                                                                            state = fold(apply, events)
                                                                            decide(state, cmd, now) → events
                                                                            append(events, expected seq) ──▶ PostgreSQL
                                                                            start Task: authorize ────┐      auction_events
                                                                            send_after(:close)        │      bid_keys, users,
                                                                                                      ▼      sessions
                                                                  StripeGate (token bucket + cap,  ──────▶ Stripe (test mode)
                                                                    reserve for cancel/capture)            or the HTTP fake
                                                                  HoldKeeper (desired vs live holds,
                                                                    cancels the difference, captures winners)
 POST /api/stripe/webhook ─────────────────▶ verified, nudges HoldKeeper and the auction
```

### Components
- **AuctionServer** (ADRs 0002, 0014 to 0016). A GenServer per auction, each with a small supervisor of its own under a DynamicSupervisor (ADR 0016), registered cluster-wide (ADR 0012). A sweep, at node start and on an interval, keeps one running for every unfinished auction (not closed, its winner not yet captured, or a bid with no outcome). A bid, or a snapshot read that finds no copy, starts one for any auction that exists. A finished auction's server stops when idle. On start it replays its events to rebuild state and schedules its close (ADR 0007). A bid arrives as a call. The server:
  1. runs the pre-check in memory;
  2. appends `bid_placed`;
  3. starts a supervised Task for the authorization through the gate.

  A bid the pre-check refuses is still a bid. The server appends `bid_placed` and `bid_rejected` together, with the rule as the reason (`below_minimum`, `ended`, `not_open`) and the `bid_keys` row, and calls nobody. The caller gets `201` with the rejected bid, can poll it, and a retry of the key gets it back. Only requests the contract answers with an error (`400`, `401`, `403`, `404`, `422`, `429`) record nothing.

  It never blocks on Stripe. The Task's result comes back as a message, and the server decides it in memory against the current state, then appends the outcome. Commit order is the order in which authorizations return to the mailbox. The HTTP caller waits up to a short deadline; if the bid hasn't resolved, the caller gets `202 pending`, and the work carries on. The server replies to waiting callers with `GenServer.reply` when their bid resolves. The HTTP layer generates the bid id before the call, and a call that times out or finds its server gone never becomes a `500` (decisions log, Q-A1).
- **Core** (ADR 0004). Pure functions: `decide(state, command, now) :: {:ok, [event]} | {:error, reason}` and `apply(state, event) :: state`. They hold every rule. The invariants are functions over an event list. The server is a thin shell that feeds commands in and appends what comes out.
- **Event store** (ADRs 0003, 0005). `append(auction_id, expected_seq, events)` inserts rows with consecutive sequence numbers under `PRIMARY KEY (auction_id, seq)`, in one transaction. A conflict on that key means another writer got there first: the server crashes and its supervisor restarts it from the log. A conflict on `bid_keys` in the same transaction is different: the key is already used, so the caller gets the original bid or a `422`, and the server carries on. The one exception: if the key's bid is in this auction and the server doesn't know it, the server is behind its log and treats it as a lost seq.
- **Log first.** The in-memory state changes only after the append commits. A reply, publish or ETS write never runs ahead of the log.
- **StripeGate** (ADR 0008). A process per node holding a token bucket and an in-flight cap, sized to that node's share of the account limit. Both are configuration: the default stays under the sandbox limit, and a run against a fake records what it used. Requests are queued by class (authorize, cancel, capture), and part of the budget is kept for cancels and captures. A bid that waits too long for a token gets an honest `202` from the HTTP layer. Pre-checks reject doomed bids before they spend a call.
- **HoldKeeper** (ADR 0006). The holds that should be live follow from the state: the current high's on an open auction, the winner's until capture, and those of pending bids. Every other authorized, uncanceled hold must be canceled. HoldKeeper computes that difference at startup, on events and on an interval, and sends the cancels through the gate. It also captures winners after close. Stripe's idempotent cancels make repeating it safe.
- **Payments behaviour.** One interface with three adapters:
  - `Stripe`: our own thin client over Req (ADR 0010).
  - `HttpFake`: speaks Holdfast's shared fake's own small protocol (`POST /authorize`, `/cancel`, `/capture`, `GET /intents/:id`, `/audit`), which is not Stripe's API. `FAKE_PAYMENTS_URL` says where it is.
  - `Memory`: in-process, for unit and property tests.

  Each adapter maps its answers to one error taxonomy: declined, needs authentication, transient (retry the same key), key in flight (`409`), replayed `500` (look up the hold by metadata), and a bug (raise).
- **Reads** (ADR 0009). The AuctionServer writes its public snapshot (auction, current high, recent bids, `version`, `minimumNextBid`) to an ETS table on every change. Snapshot GETs read ETS and never touch the server. On other nodes a snapshot comes over PubSub into that node's ETS. A node that has no copy reads it from the owner once, starting the owner if none is running (ADR 0014).
- **Live updates** (ADRs 0009, 0013). The server publishes each public event on `Phoenix.PubSub` (`auction:<id>`), with the previous public event's seq. Each node's SSE connections receive it. A new connection subscribes, sends a `snapshot` event, reads any public events after the snapshot's version from `auction_events`, then follows PubSub, deduplicating by id. A resume with `Last-Event-ID` sends no snapshot and starts from that id. A previous public seq beyond what the connection has means a message was missed, and it reads the log.
- **Webhook.** Verifies Stripe's signature on the raw body, records the event id for dedupe, and nudges HoldKeeper and the auction. It speeds things up, and is never the only source of truth.

### Data model (PostgreSQL)
| Table | Key fields |
|---|---|
| `auction_events` | auction_id, seq (bigint), type, data (jsonb), inserted_at (database time); `PRIMARY KEY (auction_id, seq)` |
| `bid_keys` | user_id, idempotency_key, bid_id, auction_id, amount; `UNIQUE (user_id, idempotency_key)`, inserted in the same transaction as `bid_placed` |
| `users` | id, login, dev flag, stripe_customer_id, default_payment_method_id |
| `sessions` | id (SHA-256 of the cookie's random bytes), user_id, expires_at |
| `stripe_events` | id (Stripe event id), type, received_at |

Money is integer cents. An auction's version is the `seq` of its latest event.

### Events (v1)
| Event | Data | Public on SSE |
|---|---|---|
| `auction_created` | title, starts_at, ends_at, starting_price, min_increment | no (it's in the snapshot) |
| `bid_placed` | bid_id, user_id, amount, idempotency_key | no |
| `hold_authorized` | bid_id, payment_intent_id, amount_capturable | no |
| `bid_rejected` | bid_id, reason (a rule from the pre-check, a decline code, `authentication_required`, `processing_error`) | no |
| `bid_accepted` | bid_id, amount, alias, previous_high_bid_id | yes, `bid.accepted` |
| `bid_lost` | bid_id, reason: why it no longer qualified (`below_minimum`, `ended`, `not_open`, `not_covered`) | no |
| `hold_released` | payment_intent_id | no |
| `auction_closed` | winner_bid_id or none | yes, `auction.closed` |
| `capture_succeeded` / `capture_failed` | payment_intent_id, reason | no |
| `auction_extended` | new ends_at (soft close, if built) | yes, `auction.extended` |

Transient Stripe outcomes are not events: a bid with `bid_placed` and no outcome is re-authorized with the same key after a restart, and Stripe replays the result.

## 5. Payments: Stripe test mode
- **The hold.** One PaymentIntent per bid, with `capture_method: manual`, `off_session: true`, the saved payment method, and the bid id as the `Idempotency-Key`. Success means `requires_capture` with `amount_capturable` at least the bid amount. That's recorded as `hold_authorized` before the decision.
- **Release:** `cancel` through HoldKeeper. **Capture:** the winner's PaymentIntent at close, for the bid amount. Each cancel and capture attempt carries its own idempotency key. Landing on an intent already in the target state counts as success.
- **Card setup.** v1 serves Holdfast's page with the fake, which needs no card (`GET /api/config` says so). Real-Stripe card setup (SetupIntent, Elements) is in the contract and comes with slice 4's real test-mode suite. It's verified server-side from Stripe and never on the client's word.
- **Rate limit.** All Stripe calls go through the gate (ADR 0008). A `429` from Stripe is a transient error, and the gate backs off.
- **Keys.** The client refuses any key that isn't `sk_test_`.

## 6. Interfaces: the contract

The HTTP and SSE contract is Holdfast's, kept stable so Holdfast's page and k6 storm run unchanged and a comparison stays possible. Its sources are Holdfast's spec §6, its `load/storm.ts` and its page, read at the pinned commit (decisions log, Q-R2). Where the spec there says less than the page and the storm need, this section records what those two clients need. They were re-read at slice 3.

**Origin:** every request other than `GET` and `HEAD` must carry the app's configured origin, or gets `403`. The one exception is `POST /api/stripe/webhook`, which is verified by its signature.

**Routes**

| Route | Answers |
|---|---|
| `POST /api/auth/dev` `{ login }` (only with dev sign-in enabled) | `204` and the `holdfast_session` cookie; `400` unless `login` is 1 to 39 of `A-Z a-z 0-9 -`; `429` rate limited |
| `POST /api/auth/logout` | `204` |
| `GET /api/config` | `{ githubSignIn, devSignIn, cardRequired, stripePublishableKey }` |
| `GET /api/me` | `{ user: { login }, hasCard, cardRequired }`, or `401` signed out |
| `POST /api/me/card/setup`, `POST /api/me/card` `{ setupIntentId }` (real Stripe only) | `{ clientSecret }`, then `{ hasCard: true }` or `422` |
| `GET /api/auctions` | `{ auctions: [{ id, title, status, endsAt, currentHigh }] }`: live, upcoming, and ended within the last day; `currentHigh` is an amount or null |
| `GET /api/auctions/:id` | the snapshot, or `404` |
| `POST /api/auctions/:id/bids` `{ amount }` with `Idempotency-Key` | see below |
| `GET /api/bids/:id` | `{ bid }` for its own bidder; `401` signed out; `404` for anyone else |
| `GET /api/auctions/:id/events` | SSE, or `404` |
| `POST /api/stripe/webhook` | signature verified |

**Placing a bid**
- `201 { bid }` resolved (`accepted`, `lost_race` or `rejected` with a reason);
- `202 { bid }` still `pending`;
- `400` bad body or a missing key (1 to 100 characters); `401` signed out; `403` wrong origin; `404` unknown auction;
- `422` key reused with a different auction or amount, even if the first bid was rejected; `429` rate limited;
- `503` the server can't find out what happened to the bid. A retry with the same key is safe.

The body is `{ amount }` alone, from 1 to 99,999,999 cents. A key is UTF-8 without NUL. Any route answers `503` if the database is unreachable. The card routes and the webhook arrive with Stripe (slice 4) and are `404` until then.

A retry with the same key and amount returns the same bid as it stands now. A bid after the close is `201`, `rejected`, `ended`. Errors are `{ error, message }`.

**Shapes**
- **Ids:** auction ids are UUIDs. The page routes on them.
- **Bid:** `{ id, auctionId, amount, status, reason, createdAt, resolvedAt }`. `status` is `pending`, `accepted`, `outbid`, `lost_race`, `rejected` or `won`. `outbid` and `won` are derived from later events: a bid once accepted is only ever `accepted`, `outbid` or `won`.
- **Snapshot:** `{ auction: { id, title, status, startsAt, endsAt, startingPrice, minIncrement, version, minimumNextBid }, currentHigh, recentBids, you }`. The auction `status` is `scheduled`, `open`, `closed` or `settled`. `minimumNextBid` is null once closed. `currentHigh` is a public bid or null, `recentBids` the latest twenty accepted, newest first, and `you` the caller's alias or null.
- **Public bid:** `{ version, amount, bidder, at }`. `at` is the database time of the `bid_accepted` row.
- Money is integer cents, and times are ISO 8601.

**SSE**
- A new connection gets `retry`, then `event: snapshot` with the snapshot, its id the auction version. The page shows nothing until it arrives.
- `bid.accepted`: `{ type, version, amount, bidder, at }`.
- `auction.closed`: `{ type, version, status, winner, amount }`, with nulls when there were no bids.
- `auction.extended`, if soft close is built.
- An event is the same whether it arrives live or is read from the log: every field comes from the log up to that event. So the append returns each row's database time, and `status` in `auction.closed` is always `closed`, even once the snapshot says `settled`.
- Each event's id is its auction version. With `Last-Event-ID`, the stream sends the public events after it and no snapshot. Comment lines keep an idle stream open.

**Pages:** the node serves the built page, and a `GET` for a page route such as `/auctions/:id` gets `index.html`. Unknown paths under `/api/` stay JSON `404`s.

**Public identity:** per-auction aliases (an HMAC of user and auction), never user ids or logins.

**What's load-bearing for a comparison:**
- the routes and status codes above;
- the session cookie;
- `minimumNextBid`;
- idempotency semantics;
- SSE event names;
- versions that increase;
- `Last-Event-ID` resume.

Holdfast's versions go up by exactly one, while ours are event sequence numbers with gaps. Holdfast's page only needs them to increase: it ignores anything at or below the version it has (`web/src/live.ts`). So gaps are part of this contract, and a comparison must not assume contiguous versions.

## 7. Invariants and failure modes

The invariants, written as functions over an auction's event list and checked by the property tests, the integration tests and the storm's checker:
1. **Covered:** every `bid_accepted` is preceded, in the same log, by a `hold_authorized` for that bid with `amount_capturable` at least the bid amount.
2. **Ordered:** accepted bids in `seq` order start at or above `starting_price` and rise by at least `min_increment`, and exactly one is the current high.
3. **Closed is closed:** no `bid_accepted` has database time (`inserted_at`) at or after `ends_at` as it stood at that point in the log. The append of a `bid_accepted` is guarded by database time, not the node's clock (ADR 0007).
4. **No orphaned holds:** once everything is idle, the only live holds at the payment provider are the current high's (open) and the winner's (closed, until settled).
5. **Idempotent:** a retry with the same user and key never creates a second hold or bid.

And the design rule they rest on, tested directly:

6. **Log first, single writer:** in-memory state never runs ahead of the committed log, and two writers for one auction can never both append the same `seq`.

| Failure | What happens |
|---|---|
| Stripe declines or needs auth | `bid_rejected` with the reason. No hold exists, or the stray intent is canceled. |
| Stripe slow, `429`, `409` in flight, connection lost | The bid stays pending. The caller gets `202` and polls. The Task retries the same key through the gate. |
| Stripe replays a `500` | The adapter looks up the hold by the bid id in metadata. Found → decide on it. None → `bid_rejected` `processing_error`. |
| AuctionServer crashes mid-bid | The supervisor restarts it. Replay rebuilds state. Bids with `bid_placed` and no outcome are re-authorized with the same key, and Stripe replays the result. HoldKeeper cancels anything left over. |
| Two writers for one auction (rolling deploy, netsplit) | The second append hits the sequence constraint and fails. That server crashes and replays. Holds it placed are canceled by HoldKeeper. |
| Node dies | Its unfinished auctions restart on the next request or the next sweep, on any running node (ADR 0014). Replay as above. |
| Two bids race at the same amount | The first authorization back to the mailbox wins. The other is `bid_lost`, and its hold is canceled. |
| Close timer fires while authorizations are in flight | `auction_closed` is appended. Later results decide as `bid_lost` (reason `ended`), and their holds are canceled. |
| Capture fails at close | `capture_failed` is recorded and retried with backoff. An alert fires after repeated failures, and the runbook covers it. |
| PubSub message lost | The next event's previous public seq is beyond what the SSE connection has (ADR 0013), or the slow poll catches it, and the connection reads the log. |

**Ordering note:** commit order, not click order, decides ties. A bidder who clicked first can lose to one whose authorization came back faster. One honest line in the UI and the case study says so.

**The biggest risk** is the single-writer guarantee across deploys and crashes. The spec treats it as the part that must be airtight. The sequence constraint is the backstop. A test kills the server at every step, and another runs a second writer that must lose.

## 8. Observability
- **Logs:** structured, with request id, auction id, bid id, seq and PaymentIntent id. No card data ever reaches the server.
- **Traces:** OpenTelemetry from `:telemetry` events. One bid's trace covers:
  - the HTTP request;
  - the call into the AuctionServer;
  - the append;
  - the gate wait;
  - the Stripe call;
  - the decision append;
  - the PubSub publish;
  - the SSE write on each node.

  The trace context travels in the call and in the PubSub message. A picture of one bid's trace is an acceptance criterion.
- **Metrics:**
  - Bids by outcome and reason.
  - Authorization latency.
  - Gate queue time and tokens by class.
  - Pending bids by age.
  - Replay time per auction start.
  - Holds live at the provider that shouldn't be. This one is the alarm.
- **Alerts:**
  - Orphaned holds above zero for more than a few minutes.
  - Repeated capture failures.
  - The gate starving cancels.
  - The budget alert.

## 9. Security
- Secrets (Stripe keys, webhook secret, session secret, alias key) live in the host's secret store, never in the repo, logs or PR text.
- At startup, production refuses: non-`sk_test_` keys, a non-`https` app origin, and dev sign-in unless deployed access says otherwise (decisions log, Q-D1).
- Sessions: `HttpOnly`, `Secure`, `SameSite=Lax` cookies with 32 random bytes; only their SHA-256 is stored. Origin check on state-changing requests, against the configured app origin and not the request's `Host`; the signed Stripe webhook is exempt.
- Request bodies are validated, and amounts are integers in a sane range. Bids are rate-limited per user, sign-in per IP. Both limits are configuration: a load run signs every bidder in from one address, so it raises them and records the values.
- Webhook signatures are verified on the raw body.
- gitleaks in CI; `.env.example` holds placeholders only.

## 10. Testing and CI
- **Property tests (StreamData) on the core, the main correctness evidence:**
  - Random command sequences with random authorization outcomes and orders, and random times around `ends_at`. Every resulting log must satisfy invariants 1 to 5.
  - Random crash points: truncate the log at any event, replay, continue with the remaining commands, and check the invariants.
  - Idempotent replays of the same key.
- **Unit:** the rules, `minimumNextBid`, the gate's bucket arithmetic, the payments error taxonomy, aliases.
- **Integration (real Postgres; a service container in CI):**
  - Append and replay.
  - A second writer that must lose.
  - The AuctionServer killed at every step of a bid, then restarted.
  - The close timer with in-flight authorizations.
  - HoldKeeper against the in-memory fake with failing cancels.
  - The two unique conflicts told apart: a used key against a second writer.
  - A bid call that times out, and one whose server dies, before and after `bid_placed` commits.
  - The sweep: an auction with no bids still closes after a restart.
- **Contract:** HTTP and SSE against §6, including `Last-Event-ID` resume and the status codes.
- **Payments:** the `HttpFake` adapter against Holdfast's shared fake for failure injection it can do over HTTP: latency, declines, failing cancels, and `503` for a lost response or a key still in flight. The fake never sends a `409`, and it recovers its simulated `500` itself, so the Stripe adapter's handling of `409` and replayed `500` is tested against stubbed Stripe responses. Plus an opt-in real test-mode suite, run by hand before payment-touching merges and never in CI.
- **Load:** Holdfast's `load/storm.ts` (k6 in Docker) from the pinned commit, then our checker. The storm first runs at slice 3 against one node and the in-memory adapter, adds the shared fake and the checker at slice 4, and moves to two clustered nodes behind a round-robin proxy at slice 5. Our checker reads the event log and the fake's `GET /audit` and applies the invariant functions. It fails on any violation, any give-up, or a run where nothing was accepted. CI runs a short storm from slice 4, and bigger runs are by hand. The fake's latency and fault settings are written down with each run.
- **Seeding:** there's no endpoint for creating auctions. A command opens one that ends after a given number of seconds and prints its id, for the storm, local runs and the demo. Holdfast's `load/run.sh` calls Holdfast's own seed and checker, so we write our own runner around the same `storm.ts`.
- **CI on every PR:** `mix format --check-formatted`, compile with warnings as errors, Credo, Dialyzer, unit, property, integration and contract tests, the short storm with the checker, gitleaks.

### Local development
`docker compose up` brings up Postgres and Holdfast's shared Stripe fake. `mix run --no-halt` runs one node. A script starts two named nodes that cluster locally. Holdfast's page is built from a pinned Holdfast commit and served by the node (decisions log, Q-R2).

## 11. Acceptance criteria (v1 "done", depth 3)
1. **Live demo:** deployed on one node. Two people in two browsers on Holdfast's page bid against each other and see updates live. In real test mode, holds appear and are released in the Stripe dashboard, and the winner is captured. A GIF is in the README.
2. **Correct:** the property tests run in CI with crash points, and the k6 storm through two clustered local nodes shows zero violations. The README gives the throughput in words, under Stripe's sandbox limit, with its spread. It isn't a comparison.
3. **Recovers:** a recorded run where a node is killed mid-storm and the checker still passes.
4. **Tests and CI:** every automated category in §10 runs on each PR. Deploys happen only from `main`.
5. **Traced:** a picture of one bid's trace across two nodes is in the README.
6. **Ops:** the alerts in §8 exist and each has been fired once on purpose. `docs/runbook.md` covers each one. The budget limit existed before the first deploy.
7. **Record:** ADRs for every expensive decision, and each PR says how AI was used and what it got wrong.

Stretch: soft close, a LiveView page (needs Phoenix; supersedes part of ADR 0010), a two-node deploy.

## 12. Slices, decisions and the comparison boundary
- The slice plan, with what each slice proves, its inputs and its done criteria, is in [plan.md](plan.md).
- Questions settled and still open, with who answers each, are in [decisions-log.md](decisions-log.md).
- The comparison is the last stage of [bid-storm](https://github.com/djwirz/bid-storm), a separate project. Where merged ADRs and older log entries say `holdfast-bench`, they mean that stage. It uses only black-box things: the §6 contract, Holdfast's shared Stripe fake, and correctness checks. Neither side is tuned mid-comparison. Nothing here is designed or tuned for it beyond keeping §6 stable: no adapter for it, no output shaped for it, and no runs of it in these slices.
