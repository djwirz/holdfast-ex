import Config

config :holdfast_ex, ecto_repos: [HoldfastEx.Repo]

# Elixir's own JSON, so there is no JSON library to depend on.
config :postgrex, :json_library, JSON

config :holdfast_ex, HoldfastEx.Repo,
  url: "ecto://postgres:postgres@localhost:5434/holdfast_ex_dev",
  pool_size: 10

config :holdfast_ex,
  # How long a bid's caller is held before it gets `pending` (spec §4).
  bid_deadline_ms: 2_000,
  # How often the sweep looks for unfinished auctions without a server (ADR 0014).
  sweep_interval_ms: 5_000,
  # How long a finished auction's server waits before it stops.
  idle_timeout_ms: 60_000

if config_env() == :test, do: import_config("test.exs")
