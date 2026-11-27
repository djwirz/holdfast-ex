import Config

config :holdfast_ex, HoldfastEx.Repo,
  url: "ecto://postgres:postgres@localhost:5434/holdfast_ex_test"

# Tests start sweeps and set timings themselves.
config :holdfast_ex, sweep_interval_ms: nil

config :logger, level: :warning
