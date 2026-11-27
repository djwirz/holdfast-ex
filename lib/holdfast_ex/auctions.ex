defmodule HoldfastEx.Auctions do
  @moduledoc """
  The way in, for HTTP (slice 3) and tests: open an auction, place a bid, read
  one. Callers never talk to a server directly.
  """

  alias HoldfastEx.Auction
  alias HoldfastEx.AuctionSupervisor
  alias HoldfastEx.Event
  alias HoldfastEx.EventStore
  alias HoldfastEx.PublicView
  alias HoldfastEx.Snapshots

  @call_margin_ms 1_000
  @attempts 3
  @retry_wait_ms 50
  # The column is a bigint. A sane range for the contract is HTTP's job (spec §9).
  @max_amount 9_223_372_036_854_775_807

  @type bid :: %{
          id: String.t(),
          auction_id: Ecto.UUID.t(),
          user_id: String.t(),
          amount: pos_integer(),
          status: :pending | :accepted | :rejected | :lost,
          reason: Event.BidRejected.reason() | Event.BidLost.reason() | nil
        }

  @type bid_error :: :not_found | :invalid_bid | :key_reused | :bid_id_taken | :unavailable

  @doc false
  def server_name(auction_id), do: via({:server, auction_id})

  @doc false
  def supervisor_name(auction_id), do: via({:supervisor, auction_id})

  defp via(key), do: {:via, Registry, {HoldfastEx.Registry, key}}

  @doc "The running server of an auction, if there is one."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(auction_id) do
    case Registry.lookup(HoldfastEx.Registry, {:server, auction_id}) do
      # The registry can still hold a server that has just died.
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Records a new auction and starts its server. `opts` are the server's."
  @spec create(map(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid_auction}
  def create(params, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    with {:ok, id} <- record(params, now.()),
         :ok <- ensure_started(id, opts) do
      {:ok, id}
    end
  end

  @doc "Writes a new auction to the log, starting nothing."
  @spec record(map(), DateTime.t()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid_auction}
  def record(params, now \\ DateTime.utc_now()) do
    id = Ecto.UUID.generate()

    with {:ok, events} <- Auction.decide(Auction.new(), {:create, params}, now),
         {:ok, _} <- EventStore.append(id, 1, events) do
      {:ok, id}
    end
  end

  @doc """
  An auction's public view: this node's copy, or, with none, its server's, which
  is started if need be (ADR 0014).
  """
  @spec view(String.t()) :: {:ok, PublicView.t()} | {:error, :not_found | :unavailable}
  def view(auction_id) do
    with nil <- Snapshots.get(auction_id),
         :ok <- ensure_started(auction_id) do
      {:ok, GenServer.call(server_name(auction_id), :view)}
    else
      %PublicView{} = view -> {:ok, view}
      error -> error
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Starts the server of any auction that exists, unless it is running (ADR 0014).
  `opts` apply only if this call starts it.
  """
  @spec ensure_started(Ecto.UUID.t(), keyword()) :: :ok | {:error, :not_found}
  def ensure_started(auction_id, opts \\ []) do
    cond do
      whereis(auction_id) -> :ok
      Ecto.UUID.cast(auction_id) != {:ok, auction_id} -> {:error, :not_found}
      not EventStore.exists?(auction_id) -> {:error, :not_found}
      true -> start(Keyword.put(opts, :auction_id, auction_id))
    end
  end

  defp start(opts) do
    case DynamicSupervisor.start_child(HoldfastEx.AuctionSupervisors, {AuctionSupervisor, opts}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Places a bid and waits up to the deadline for its outcome. A bid still
  unresolved then comes back `:pending`, and the work carries on.

  It never raises for a server that is slow or gone, and never says `:pending`
  for a bid that isn't in the log (Q-A1): it looks the key up, and either answers
  with that bid or tries again. `{:error, :unavailable}` means it couldn't find
  out, and a retry with the same key is safe.

  `opts`: `:bid_id` (made here otherwise), `:deadline_ms`, `:call_margin_ms`.
  """
  @spec place_bid(
          Ecto.UUID.t(),
          %{user_id: String.t(), amount: pos_integer(), idempotency_key: String.t()},
          keyword()
        ) :: {:ok, bid()} | {:error, bid_error()}
  def place_bid(auction_id, %{amount: amount} = bid, opts \\ []) do
    if is_integer(amount) and amount > 0 and amount <= @max_amount do
      params = Map.put(bid, :bid_id, Keyword.get_lazy(opts, :bid_id, &Ecto.UUID.generate/0))
      attempt(auction_id, params, opts, @attempts)
    else
      {:error, :invalid_bid}
    end
  end

  defp attempt(auction_id, params, opts, left) do
    case ensure_started(auction_id) do
      :ok -> call(auction_id, params, opts, left)
      error -> error
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp call(auction_id, params, opts, left) do
    deadline =
      Keyword.get_lazy(opts, :deadline_ms, fn ->
        Application.fetch_env!(:holdfast_ex, :bid_deadline_ms)
      end)

    margin = Keyword.get(opts, :call_margin_ms, @call_margin_ms)

    try do
      GenServer.call(server_name(auction_id), {:place_bid, params, deadline}, deadline + margin)
    catch
      # Timed out, crashed, stopping, or not there: we don't know what it did.
      :exit, _reason -> recover(auction_id, params, opts, left)
    end
  end

  defp recover(auction_id, params, opts, left) do
    case EventStore.lookup_key(params.user_id, params.idempotency_key) do
      %{auction_id: ^auction_id, amount: amount, bid_id: bid_id} when amount == params.amount ->
        # Make sure someone is working on it.
        :ok = ensure_started(auction_id)
        {:ok, get_bid(auction_id, bid_id)}

      %{} ->
        {:error, :key_reused}

      nil when left > 1 ->
        # Safe even if the first call is still going: the key makes one bid.
        Process.sleep(@retry_wait_ms)
        attempt(auction_id, params, opts, left - 1)

      nil ->
        {:error, :unavailable}
    end
  end

  @doc "A bid as the log has it, or nil."
  @spec get_bid(Ecto.UUID.t(), String.t()) :: bid() | nil
  def get_bid(auction_id, bid_id) do
    core = Auction.replay(EventStore.load(auction_id))
    if Map.has_key?(core.bids, bid_id), do: bid_view(auction_id, core, bid_id)
  end

  @doc false
  def bid_view(auction_id, core, bid_id) do
    bid = Map.fetch!(core.bids, bid_id)

    %{
      id: bid_id,
      auction_id: auction_id,
      user_id: bid.user_id,
      amount: bid.amount,
      # A hold with no outcome yet is still pending to everyone outside.
      status: if(bid.status == :authorized, do: :pending, else: bid.status),
      reason: bid.reason
    }
  end
end
