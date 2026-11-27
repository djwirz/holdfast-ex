defmodule HoldfastEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :holdfast_ex,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      mod: {HoldfastEx.Application, []},
      extra_applications: [:logger, :crypto] ++ test_applications(Mix.env())
    ]
  end

  # The contract tests call the server with OTP's own HTTP client.
  defp test_applications(:test), do: [:inets]
  defp test_applications(_), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # ecto_sql, postgrex: the event log, invariant 6 (ADR 0010). telemetry: the
  # steps spec §10 kills the server at, and §8's traces later. plug, bandit: the
  # §6 contract (ADR 0010). phoenix_pubsub: the live path (ADRs 0009, 0013). credo, dialyxir,
  # stream_data: spec §10 and acceptance criterion 4.
  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.23"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.20"},
      {:bandit, "~> 1.15"},
      {:phoenix_pubsub, "~> 2.4"},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      flags: [:error_handling, :unmatched_returns, :extra_return, :missing_return]
    ]
  end
end
