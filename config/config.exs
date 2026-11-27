import Config

config :holdfast_ex, ecto_repos: [HoldfastEx.Repo]

# Elixir's own JSON, so there is no JSON library to depend on.
config :postgrex, :json_library, JSON

config :holdfast_ex, HoldfastEx.Repo,
  url: "ecto://postgres:postgres@localhost:5434/holdfast_ex_dev",
  pool_size: 10,
  # Query logs would carry user ids and idempotency keys.
  log: false

config :holdfast_ex,
  # How long a bid's caller is held before it gets `pending` (spec §4).
  bid_deadline_ms: 2_000,
  # How often the sweep looks for unfinished auctions without a server (ADR 0014).
  sweep_interval_ms: 5_000,
  # How long a finished auction's server waits before it stops.
  idle_timeout_ms: 60_000,
  http_port: 3000,
  # The one origin that may change anything, compared with the Origin header (spec §9).
  app_origin: "http://localhost:3000",
  secure_cookies: true,
  # Refused in production (spec §9, Q-D1).
  dev_sign_in: config_env() != :prod,
  # A placeholder. Production must set its own (runtime.exs).
  alias_key: "local-development-only-not-a-secret",
  # {requests, per milliseconds}: bids per user, sign-ins per address.
  bid_rate_limit: {10, 10_000},
  auth_rate_limit: {20, 60_000},
  # Holdfast's page, as scripts/fetch-page.sh builds it. Served if it's there.
  web_dist: Path.expand("../vendor/holdfast/web/dist", __DIR__),
  sse_heartbeat_ms: 15_000,
  sse_poll_ms: 10_000

if config_env() == :test, do: import_config("test.exs")
