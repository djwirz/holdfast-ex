defmodule HoldfastEx.AuctionServer do
  @moduledoc """
  The one process that decides an auction's bids (ADRs 0002, 0007, 0014).

  It is a thin shell around the core (ADR 0004): every message becomes a command
  for `HoldfastEx.Auction.decide/3`, the events are appended, and only then is
  the state changed and anyone answered. So memory and replies never run ahead of
  the log (invariant 6). Losing a seq to another writer stops the process, and
  its supervisor starts a fresh one from the log.

  Each step emits `[:holdfast_ex, :auction, step]` telemetry, with `auction_id`
  and sometimes `bid_id`.

  ## Options
    * `:auction_id` (required)
    * `:name` - registered under the auction id by default; `nil` for none
    * `:now` - the node's clock, `(-> DateTime.t())`
    * `:alias` - a bidder's public name, `(auction_id, user_id -> String.t())`
    * `:payments` - a `HoldfastEx.Payments` module
    * `:retry_ms` - the first wait before asking the provider again
    * `:idle_timeout_ms` - how long a finished auction's server stays
  """

  use GenServer, restart: :transient

  alias HoldfastEx.Auction
  alias HoldfastEx.Auctions
  alias HoldfastEx.Event
  alias HoldfastEx.EventStore
  alias HoldfastEx.PublicView
  alias HoldfastEx.Snapshots
  alias HoldfastEx.Web.SSE

  @max_retry_ms 5_000
  # Long waits are taken in pieces, so a clock that jumps is noticed.
  @max_close_wait_ms 60_000

  def start_link(opts) do
    name =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> name
        :error -> Auctions.server_name(Keyword.fetch!(opts, :auction_id))
      end

    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.fetch!(opts, :auction_id),
      core: Auction.new(),
      view: PublicView.new(Keyword.fetch!(opts, :auction_id)),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      alias: Keyword.get(opts, :alias, &HoldfastEx.Alias.of/2),
      payments: Keyword.get(opts, :payments, HoldfastEx.Payments.Memory),
      retry_ms: Keyword.get(opts, :retry_ms, 100),
      idle_timeout_ms:
        Keyword.get(opts, :idle_timeout_ms, Application.get_env(:holdfast_ex, :idle_timeout_ms)),
      # bid_id => callers waiting for it, each with its deadline timer
      waiters: %{},
      # Task ref => {bid_id, attempt} for authorizations in flight
      tasks: %{}
    }

    # Replay after init returns, so whoever started us isn't held up by it. It
    # still runs before any message in the mailbox.
    {:ok, state, {:continue, :replay}}
  end

  @impl true
  def handle_continue(:replay, state) do
    events = EventStore.load(state.id)
    core = Auction.replay(events)

    if core.auction == nil do
      {:stop, :normal, state}
    else
      {view, _already_published} = PublicView.fold(state.view, events)
      :ok = Snapshots.put(view)
      state = %{state | core: core, view: view}
      schedule_close(state)
      step(state, :replayed)
      resume(state)
    end
  end

  # Bids with no outcome in the log: the work a restart interrupted (spec §7).
  defp resume(state) do
    state.core.bids
    |> Enum.filter(fn {_id, bid} -> bid.status in [:pending, :authorized] end)
    |> Enum.reduce_while({:ok, state}, fn {bid_id, bid}, {:ok, state} ->
      case authorize(state, bid_id, bid, 1) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:conflict, state} -> {:halt, {:conflict, state}}
      end
    end)
    |> noreply()
  end

  # For a node that has no copy of the snapshot (ADR 0014). It runs after the
  # replay, which is ahead of it in the queue.
  @impl true
  def handle_call(:view, _from, state), do: reply(state, state.view)

  def handle_call({:place_bid, params, deadline_ms}, from, state) do
    step(state, :bid_received, params.bid_id)

    case Auction.decide(state.core, {:place_bid, params}, state.now.()) do
      {:ok, events} -> record_bid(state, events, params, from, deadline_ms)
      {:error, {:duplicate, bid_id}} -> await(state, bid_id, from, deadline_ms)
      {:error, reason} -> reply(state, {:error, reason})
    end
  end

  defp record_bid(state, events, %{bid_id: bid_id} = params, from, deadline_ms) do
    case commit(state, events) do
      {:ok, state} ->
        step(state, :bid_placed, bid_id)

        case state.core.bids[bid_id] do
          %{status: :pending} = bid ->
            # A pending bid has no hold yet, so this only starts the Task.
            {:ok, state} = authorize(state, bid_id, bid, 1)
            await(state, bid_id, from, deadline_ms)

          _refused ->
            await(state, bid_id, from, deadline_ms)
        end

      {:error, {:key_used, original}} ->
        used_key(state, original, params)

      {:error, :conflict} ->
        {:stop, :conflict, state}
    end
  end

  # The database knows a key the core didn't. For another auction or amount that
  # is the caller's mistake. For a bid of this auction it means our state is
  # behind the log: another writer.
  defp used_key(state, original, params) do
    cond do
      original.auction_id != state.id or original.amount != params.amount ->
        reply(state, {:error, :key_reused})

      Map.has_key?(state.core.bids, original.bid_id) ->
        reply(state, {:ok, Auctions.bid_view(state.id, state.core, original.bid_id)})

      true ->
        {:stop, :conflict, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{bid_id, attempt}, tasks} = Map.pop!(state.tasks, ref)
    state = %{state | tasks: tasks}

    case result do
      {:transient, _reason} -> retry_later(state, bid_id, attempt)
      final -> noreply(resolve(state, bid_id, final))
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.tasks, ref) do
    {{bid_id, attempt}, tasks} = Map.pop!(state.tasks, ref)
    retry_later(%{state | tasks: tasks}, bid_id, attempt)
  end

  def handle_info({:retry, bid_id, attempt}, state) do
    case state.core.bids[bid_id] do
      %{status: status} = bid when status in [:pending, :authorized] ->
        noreply(authorize(state, bid_id, bid, attempt))

      _resolved ->
        noreply({:ok, state})
    end
  end

  # The caller has waited long enough: it gets the bid as it stands (`pending`).
  def handle_info({:deadline, bid_id, from}, state) do
    {due, rest} =
      state.waiters |> Map.get(bid_id, []) |> Enum.split_with(fn {f, _timer} -> f == from end)

    for {from, _timer} <- due do
      GenServer.reply(from, {:ok, Auctions.bid_view(state.id, state.core, bid_id)})
    end

    waiters =
      if rest == [],
        do: Map.delete(state.waiters, bid_id),
        else: Map.put(state.waiters, bid_id, rest)

    noreply({:ok, %{state | waiters: waiters}})
  end

  def handle_info(:close, state) do
    step(state, :close_due)

    case Auction.decide(state.core, :close, state.now.()) do
      {:ok, events} ->
        case commit(state, events) do
          {:ok, state} ->
            step(state, :closed)
            noreply({:ok, state})

          {:error, :conflict} ->
            {:stop, :conflict, state}
        end

      {:error, :not_due} ->
        schedule_close(state)
        noreply({:ok, state})
    end
  end

  # Only a finished auction sets this timeout (see `idle/1`).
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # -- authorization ---------------------------------------------------------

  # The log already has the hold: decide on it, without asking the provider.
  defp authorize(state, bid_id, %{status: :authorized} = bid, _attempt),
    do: resolve(state, bid_id, {:ok, bid.payment_intent_id, bid.amount_capturable})

  # Under a Task.Supervisor and not linked: we never block on the provider, and a
  # crash there reaches us as a message, not as our own death.
  defp authorize(state, bid_id, bid, attempt) do
    request = %{auction_id: state.id, bid_id: bid_id, user_id: bid.user_id, amount: bid.amount}

    task =
      Task.Supervisor.async_nolink(HoldfastEx.TaskSupervisor, state.payments, :authorize, [
        request
      ])

    step(state, :authorize_started, bid_id)
    {:ok, put_in(state.tasks[task.ref], {bid_id, attempt})}
  end

  defp retry_later(state, bid_id, attempt) do
    wait = min(state.retry_ms * Integer.pow(2, min(attempt - 1, 10)), @max_retry_ms)
    _ = Process.send_after(self(), {:retry, bid_id, attempt + 1}, wait)
    noreply({:ok, state})
  end

  defp resolve(state, bid_id, result) do
    step(state, :authorization_received, bid_id)
    decide_outcome(state, bid_id, result, state.now.())
  end

  defp decide_outcome(state, bid_id, result, now) do
    %{user_id: user_id} = Map.fetch!(state.core.bids, bid_id)

    command =
      {:authorization, %{bid_id: bid_id, alias: state.alias.(state.id, user_id), result: result}}

    {:ok, events} = Auction.decide(state.core, command, now)

    case commit(state, events) do
      {:ok, state} ->
        step(state, :outcome_appended, bid_id)
        {:ok, settle(state, bid_id)}

      # Our clock is behind the database's, which is the one that counts
      # (ADR 0007). Decide again at its time: the core then says `ended`.
      {:error, {:past_end, database_now}} ->
        decide_outcome(state, bid_id, result, database_now)

      {:error, :conflict} ->
        {:conflict, state}
    end
  end

  # -- the log ---------------------------------------------------------------

  # The only place state changes: after the append has committed.
  defp commit(state, events) do
    next_seq = state.core.version + 1

    with {:ok, stamped} <- EventStore.append(state.id, next_seq, events, guard(state, events)) do
      core = Enum.reduce(stamped, state.core, &Auction.apply(&2, &1))
      {:ok, show(%{state | core: core}, stamped)}
    end
  end

  # Readers hear of it only now, and callers after them. A lost message is read
  # back from the log (ADR 0013).
  defp show(state, stamped) do
    {view, published} = PublicView.fold(state.view, stamped)
    :ok = Snapshots.put(view)

    Enum.each(published, fn {previous, event} ->
      message = {:holdfast_event, previous, event}
      :ok = Phoenix.PubSub.broadcast(HoldfastEx.PubSub, SSE.topic(state.id), message)
    end)

    %{state | view: view}
  end

  # Only an accept is refused by time: everything else must be appendable late.
  defp guard(state, events) do
    if Enum.any?(events, &match?(%{data: %Event.BidAccepted{}}, &1)),
      do: [ends_at: state.core.auction.ends_at],
      else: []
  end

  # -- callers ---------------------------------------------------------------

  defp await(state, bid_id, from, deadline_ms) do
    if state.core.bids[bid_id].status in [:pending, :authorized] do
      timer = Process.send_after(self(), {:deadline, bid_id, from}, deadline_ms)
      waiter = {from, timer}
      waiters = Map.update(state.waiters, bid_id, [waiter], &[waiter | &1])
      noreply({:ok, %{state | waiters: waiters}})
    else
      reply(state, {:ok, Auctions.bid_view(state.id, state.core, bid_id)})
    end
  end

  # A late reply to a caller that gave up is dropped by the runtime (Q-V2), so
  # there is nothing to check before replying.
  defp settle(state, bid_id) do
    {waiting, waiters} = Map.pop(state.waiters, bid_id, [])

    for {from, timer} <- waiting do
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, Auctions.bid_view(state.id, state.core, bid_id)})
    end

    if waiting != [], do: step(state, :replied, bid_id)
    %{state | waiters: waiters}
  end

  # -- helpers ---------------------------------------------------------------

  defp schedule_close(%{core: %{closed: nil, auction: auction}} = state) do
    # Rounded up, so the timer never fires a fraction early.
    wait = div(DateTime.diff(auction.ends_at, state.now.(), :microsecond) + 999, 1_000)
    _ = Process.send_after(self(), :close, wait |> max(0) |> min(@max_close_wait_ms))
    :ok
  end

  defp schedule_close(_closed), do: :ok

  defp reply(state, reply), do: {:reply, reply, state, idle(state)}

  defp noreply({:ok, state}), do: {:noreply, state, idle(state)}
  defp noreply({:conflict, state}), do: {:stop, :conflict, state}

  # The timeout is cancelled by any message, so it means "nothing happened for
  # this long". Only a finished auction with nothing pending may stop.
  defp idle(%{core: core} = state) do
    finished? =
      match?(%{winner_bid_id: nil}, core.closed) or core.capture == :succeeded

    pending? = Enum.any?(core.bids, fn {_id, bid} -> bid.status in [:pending, :authorized] end)

    if finished? and not pending?, do: state.idle_timeout_ms, else: :infinity
  end

  defp step(state, name, bid_id \\ nil) do
    metadata = %{auction_id: state.id, bid_id: bid_id}
    :telemetry.execute([:holdfast_ex, :auction, name], %{}, metadata)
  end
end
