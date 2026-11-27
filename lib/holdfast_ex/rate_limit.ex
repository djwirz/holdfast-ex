defmodule HoldfastEx.RateLimit do
  @moduledoc """
  A fixed-window counter in ETS, per node (spec §9). It's a courtesy to the
  service, not a guard on correctness, so a restart forgetting it is fine.

  Counting happens in the caller with an atomic ETS update. The process only owns
  the table and clears old windows.
  """

  use GenServer

  @clean_every_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Counts one request for `key`; `false` once over `max` in this window."
  @spec allow?(term(), {pos_integer(), pos_integer()}) :: boolean()
  def allow?(key, {max, window_ms}) do
    now = System.monotonic_time(:millisecond)
    window = Integer.floor_div(now, window_ms)
    row = {key, window}
    :ets.update_counter(__MODULE__, row, {2, 1}, {row, 0, now + window_ms}) <= max
  end

  def reset do
    true = :ets.delete_all_objects(__MODULE__)
    :ok
  end

  @impl true
  def init(nil) do
    _ = :ets.new(__MODULE__, [:named_table, :public, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:clean, state) do
    now = System.monotonic_time(:millisecond)
    _ = :ets.select_delete(__MODULE__, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule do
    _ = Process.send_after(self(), :clean, @clean_every_ms)
    :ok
  end
end
