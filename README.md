# holdfast-ex

Real-time auctions in Elixir/OTP where a bid counts only once a Stripe test-mode hold covers it. Each auction is one supervised process that rebuilds itself from an append-only event log, so a crash is a restart, not a repair. Holds that stop mattering follow from the state and are released by one loop, and Stripe's rate limit is part of the design.

**Status:** slices 1 to 3 of 7 are built: the pure core with its property tests, the event log in Postgres, one supervised process per auction, and the HTTP and SSE contract with Holdfast's page and storm running against it. Payments are still an in-memory stand-in, so nothing talks to Stripe yet. Design: [docs/spec.md](docs/spec.md), [docs/adr/](docs/adr/), [docs/plan.md](docs/plan.md) and [docs/decisions-log.md](docs/decisions-log.md). Stripe test mode and synthetic data only.

## Development
Elixir and OTP at the versions in [.tool-versions](.tool-versions), and Docker for Postgres.

```bash
docker compose up -d --wait
```

```bash
mix deps.get
```

```bash
mix test
```

`mix test` creates and migrates its own database, and empties it as it goes. For a local node, create the development one first:

```bash
mix do ecto.create + ecto.migrate
```

CI also runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer` and gitleaks. `PROPERTY_RUNS=20000 mix test` runs the property tests longer.

## Run it
Holdfast's page is built once from a pinned commit (Node 26 or later, and pnpm):

```bash
scripts/fetch-page.sh
```

```bash
mix run --no-halt
```

In another terminal, open an auction that ends in five minutes, then visit http://localhost:3000 in Chrome or Firefox (Safari won't send the `Secure` session cookie over local HTTP):

```bash
mix holdfast.seed --ends-in 300
```

## Storm
Holdfast's k6 storm, unchanged, against one node, then the invariants over the auction's log. It starts its own node on port 3000, needs Docker, and is a correctness check, not a benchmark:

```bash
scripts/storm.sh
```
