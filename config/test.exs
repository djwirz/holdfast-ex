import Config

config :holdfast_ex, HoldfastEx.Repo,
  url: "ecto://postgres:postgres@localhost:5434/holdfast_ex_test"

# Tests start sweeps and set timings themselves, and their own server on a free port.
config :holdfast_ex,
  sweep_interval_ms: nil,
  http_port: nil,
  web_dist: nil

config :logger, level: :warning
