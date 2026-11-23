# holdfast-ex

Real-time auctions in Elixir/OTP where a bid counts only once a Stripe test-mode hold covers it. Each auction is one supervised process that rebuilds itself from an append-only event log, so a crash is a restart, not a repair. Holds that stop mattering follow from the state and are released by one loop, and Stripe's rate limit is part of the design.

**Status:** planning. Design: [docs/spec.md](docs/spec.md), [docs/adr/](docs/adr/), [docs/plan.md](docs/plan.md) and [docs/decisions-log.md](docs/decisions-log.md). Stripe test mode and synthetic data only.
