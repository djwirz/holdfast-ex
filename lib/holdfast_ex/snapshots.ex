defmodule HoldfastEx.Snapshots do
  @moduledoc """
  This node's copy of each auction's public view, in ETS (ADR 0009). Reads never
  touch an auction's server. Its server writes it, after the append commits, and
  the row stays when a finished server stops (ADR 0014).

  The process only owns the table: a table dies with its owner.
  """

  use GenServer

  alias HoldfastEx.PublicView

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec put(PublicView.t()) :: :ok
  def put(%PublicView{} = view) do
    true = :ets.insert(__MODULE__, {view.id, view})
    :ok
  end

  @spec get(String.t()) :: PublicView.t() | nil
  def get(auction_id) do
    case :ets.lookup(__MODULE__, auction_id) do
      [{_, view}] -> view
      [] -> nil
    end
  end

  @doc "Forgets a copy, as a node that never had it. For tests."
  def delete(auction_id) do
    true = :ets.delete(__MODULE__, auction_id)
    :ok
  end

  @impl true
  def init(nil) do
    _ = :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
