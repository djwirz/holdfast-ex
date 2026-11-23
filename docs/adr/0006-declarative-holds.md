# 6. Holds are declarative: one loop cancels what shouldn't exist

Date: 2026-11-23
Status: Accepted

## Context
Every lost, outbid or abandoned bid leaves a hold that must be released (invariant 4). Holds can also be left by a crash between authorizing and recording, by a second writer that lost (ADR 0005), or by an authorization that returns after close. A to-do list of cancels written beside each decision (an outbox) has to be written correctly on every path and can't see holds it never recorded.

## Options considered
1. **Declarative holds.** The state implies which holds should be live: the current high's on an open auction, the winner's until capture, and those of bids still pending. HoldKeeper lists live holds at the provider, computes the difference, and cancels the rest, at startup, on events and on an interval. It also captures winners after close.
2. **An outbox of cancel and capture jobs** written in the same transaction as each decision, plus a separate reconciler for crashes. Precise and familiar, but two mechanisms, and holds placed by a crashed or losing writer need the second one anyway.
3. **Cancel inline** right after each decision. The simplest, but a crash at the wrong moment leaks a hold with no record of it.

## Decision
Option 1. The intent is written first: `bid_placed` is appended before Stripe is called, with the bid id as the idempotency key. So a bid with no outcome after a crash is re-authorized, and Stripe replays the original result. Everything else follows from the state.

## Why
One mechanism covers every source of a stray hold, including ones the system never recorded. It's safe to run any number of times, because Stripe cancels are idempotent and the loop only ever moves the world toward the state.

## Consequences
- Listing holds at the provider costs Stripe calls. It's scoped to customers and recent intents with our metadata, and it goes through the gate's reserve (ADR 0008).
- "Pending" protection: the loop never cancels the hold of a bid still pending in a live server, or the decision could lose a covered bid. Exact rules in spec §7 and the slice 4 plan.
- In-flight authorizations at close resolve as `bid_lost` (reason `ended`), and their holds fall out of the desired set.
- This is still a reconciler, honestly named. The claim is one reconciler derived from state, not none.
