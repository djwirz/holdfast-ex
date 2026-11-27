defmodule HoldfastEx.Web do
  @moduledoc "The HTTP server: Bandit running `HoldfastEx.Web.Router` (ADR 0010)."

  @doc "A child spec for `port` on `ip`. `port: 0` takes any free port."
  def child_spec(opts) do
    Bandit.child_spec(
      plug: HoldfastEx.Web.Router,
      scheme: :http,
      port: Keyword.fetch!(opts, :port),
      ip: Keyword.get(opts, :ip, :loopback),
      startup_log: Keyword.get(opts, :startup_log, :info),
      # Compressing would buffer the event stream.
      http_options: [compress: false],
      # SSE connections never finish by themselves, so don't wait long for them.
      thousand_island_options: [shutdown_timeout: 1_000]
    )
  end
end
