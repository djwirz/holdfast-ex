defmodule HoldfastEx.Sweep do
  @moduledoc """
  Keeps a server running for every unfinished auction (ADRs 0014, 0015), at node
  start and on an interval. It only starts servers: they decide everything.

  Options: `:interval_ms` (`nil` never sweeps by itself) and `:server_opts`.
  """

  use GenServer

  alias HoldfastEx.Auctions
  alias HoldfastEx.EventStore

  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "One pass."
  @spec run(keyword()) :: :ok
  def run(server_opts \\ []) do
    Enum.each(EventStore.unfinished_ids(), &Auctions.ensure_started(&1, server_opts))
  rescue
    # The database being away must not take the sweep with it.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("sweep failed: #{Exception.message(error)}")
  end

  @impl true
  def init(opts) do
    state = %{interval: opts[:interval_ms], server_opts: Keyword.get(opts, :server_opts, [])}
    if state.interval, do: {:ok, state, {:continue, :sweep}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:sweep, state), do: {:noreply, sweep(state)}

  @impl true
  def handle_info(:sweep, state), do: {:noreply, sweep(state)}

  defp sweep(state) do
    :ok = run(state.server_opts)
    _ = Process.send_after(self(), :sweep, state.interval)
    state
  end
end
