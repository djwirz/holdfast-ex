# holdfast-ex: instructions for Claude

Real-time auctions in Elixir/OTP where a bid counts only once a Stripe test-mode authorization hold covers it. Each auction is one supervised process that decides its bids and rebuilds itself from an append-only event log. Holds are derived from state, and Stripe's rate limit is a designed constraint. It keeps Holdfast's HTTP and SSE contract, so Holdfast's page and k6 storm run against it unchanged. Use they/them for Dan.

## Status
Slice 1 (foundation and the pure core) is built: `lib/holdfast_ex/` has the events, the core and the invariants, with property tests and CI. Next is slice 2 (event store and the auction process). Design: `docs/spec.md`, ADRs 0001–0014, `docs/plan.md` and `docs/decisions-log.md`. Open questions are in the decisions log, each with who answers it and by which slice. The judgment behind the project is in `docs/artifact-spec.md`.

## How we work
- Pull requests only. Never push to `main`. Merged PRs are the project's record.
- Spec first, then one thin end-to-end slice per PR (`docs/plan.md`). Start each slice in plan mode.
- **Problem first.** Every tool, feature and dependency has to earn its place through an invariant, a failure mode in spec §7, or an acceptance criterion in §11. Each slice's plan says which one for anything new. Skills shown are a by-product.
- Every decision that would be expensive to reverse gets an ADR in `docs/adr/` (format: ADR 0001). Don't decide quietly in code. Record each question settled, or still open, in `docs/decisions-log.md`.
- ADRs are written as `Accepted` in the PR that adds them, and merging is the acceptance. Never rewrite a merged ADR's decision. Add a new ADR that supersedes it.
- When the spec and the code disagree, stop and ask. If the decision changes, update the spec in the same PR.
- Elixir and OTP are new ground for Dan. Explain the OTP idea behind each new piece briefly in the PR description, so the PR doubles as notes.
- Built with Claude Code in the open: the case study gets a section on how AI was used and where it was wrong, so note real mistakes in PR descriptions.

## Constraints
- **Elixir/OTP is the point.** The service is Elixir. Check current Elixir, OTP and library versions and APIs against their docs before pinning or using anything. Never trust the handoff or this repo's docs for versions.
- **Independent of Holdfast.** No design choice here may be justified by how Holdfast does it. `~/projects/holdfast` is read-only from here. Never edit it. Its contract, shared Stripe fake and k6 storm are used as black boxes from a pinned commit.
- **No comparison.** No benchmark against Holdfast and no tuning meant to win one. That's the last stage of `bid-storm`, a separate project (`~/projects/bid-storm`, read-only from here). Keep spec §6 stable.
- Stripe **test mode** only (`sk_test_` keys). Synthetic data only. Never employer code, data or names.
- Budget under about $10 a month. A hard limit and an alert exist before anything is deployed. Nothing paid without Dan's go-ahead.
- Secrets never in the repo, logs or PR text.
- Target depth: deployed, tests and CI, ADRs, observability.
- Numbers in docs: honest estimates in words, never false precision.

## Invariants (spec §7): never break these
1. **Covered:** no bid is accepted unless a `hold_authorized` for at least its amount precedes its `bid_accepted` in the log.
2. **Ordered:** accepted bids start at or above `starting_price`, rise by at least `min_increment` in `seq` order, and exactly one is the current high.
3. **Closed is closed:** no bid is accepted at or after `ends_at` by database time.
4. **No orphaned holds:** once everything is idle, the only live holds are the current high's (open) and the winner's (closed, until settled).
5. **Idempotent:** a retry with the same user and key never creates a second hold or bid.
6. **Log first, single writer:** in-memory state, replies and publishes never run ahead of the committed log. Two writers can never both append the same `seq`.
