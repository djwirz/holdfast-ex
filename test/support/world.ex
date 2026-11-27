defmodule HoldfastEx.Test.World do
  @moduledoc """
  A model of everything around the core for one auction: the log, a clock, and a
  payment provider that, like Stripe with an idempotency key, gives the same
  answer for the same bid however often it's asked.

  Actions are generated without looking at the world and resolved against it when
  they run ("the minimum plus one", "the third pending bid"), so StreamData can
  drop or shrink any of them and the rest still make sense.

  Each step also notes which interesting situations it reached, so the tests can
  show the generators actually get there.
  """

  alias HoldfastEx.Auction
  alias HoldfastEx.Event
  alias HoldfastEx.Test.Log

  # The auction of `Log.created/0`.
  @starts_ms 1_000
  @ends_ms 61_000

  defstruct log: [], state: nil, now: 0, provider: %{}, next_bid: 1, seen: MapSet.new()

  @doc "Every situation a run can note."
  def situations do
    [
      :accepted,
      :tie,
      :refused_not_open,
      :refused_below_minimum,
      :refused_ended,
      :not_covered,
      :declined,
      :bid_in_last_ms,
      :accepted_in_last_ms,
      :bid_at_ends_at,
      :result_at_ends_at,
      :result_after_close,
      :closed_with_winner,
      :repeat_same_amount,
      :repeat_changed_amount,
      :crash_with_bid_pending,
      :crash_between_hold_and_outcome,
      :crash_lost_the_close
    ]
  end

  def new(start_ms) do
    {log, state} = Log.created()
    %__MODULE__{log: log, state: state, now: start_ms}
  end

  # -- generators ------------------------------------------------------------

  @doc "Where the clock starts: sometimes before the auction opens."
  def start_ms do
    StreamData.frequency([{4, StreamData.constant(@starts_ms)}, {1, StreamData.constant(0)}])
  end

  def actions do
    StreamData.list_of(action(), max_length: 60)
  end

  # Simplest first: StreamData shrinks toward the earlier choices.
  defp action do
    StreamData.frequency([
      {10, bid()},
      {12, resolve()},
      {6, StreamData.tuple({StreamData.constant(:advance), StreamData.integer(1..3_000)})},
      {3, retry()},
      {3, StreamData.tuple({StreamData.constant(:crash), StreamData.integer(0..200)})},
      {2, jump()},
      {2, StreamData.constant(:close)}
    ])
  end

  defp bid do
    amount =
      StreamData.frequency([
        {5, StreamData.member_of([{:minimum_plus, 0}, {:minimum_plus, 1}, {:minimum_plus, 250}])},
        {1, StreamData.member_of([{:minimum_plus, -1}, {:minimum_plus, -400}])},
        {2, StreamData.tuple({StreamData.constant(:tie_with), pick()})}
      ])

    StreamData.tuple({StreamData.constant(:bid), StreamData.member_of(~w(ann bob cat)), amount})
  end

  # The first bid in the list is the oldest, so results come back in any order.
  defp resolve do
    result =
      StreamData.frequency([
        {10, StreamData.constant(:full)},
        {1, StreamData.constant(:extra)},
        {1, StreamData.constant(:short)},
        {1, StreamData.constant({:fail, "card_declined"})},
        {1, StreamData.constant({:fail, :authentication_required})},
        {1, StreamData.constant({:fail, :processing_error})}
      ])

    StreamData.tuple({StreamData.constant(:resolve), pick(), result})
  end

  defp retry do
    StreamData.tuple({StreamData.constant(:retry), pick(), StreamData.member_of([0, 0, 1])})
  end

  # Straight to a boundary, which random advances would almost never hit exactly.
  defp jump do
    boundary =
      StreamData.member_of([@starts_ms, @ends_ms - 1, @ends_ms - 1, @ends_ms, @ends_ms + 1])

    StreamData.tuple({StreamData.constant(:jump), boundary})
  end

  defp pick, do: StreamData.integer(0..50)

  # -- running actions -------------------------------------------------------

  def step(world, {:advance, ms}), do: %{world | now: world.now + ms}

  # The clock only goes forward.
  def step(world, {:jump, ms}), do: %{world | now: max(world.now, ms)}

  def step(world, {:bid, user, amount}) do
    bid_id = "b#{world.next_bid}"
    world = %{world | next_bid: world.next_bid + 1}
    command = Log.bid(bid_id, user, resolve_amount(world, amount))
    world = note_if(world, world.now == @ends_ms - 1, :bid_in_last_ms)
    world = note_if(world, world.now == @ends_ms, :bid_at_ends_at)

    world = command!(world, command)

    case world.state.bids[bid_id] do
      %{status: :rejected, reason: reason} -> note(world, :"refused_#{reason}")
      _pending -> world
    end
  end

  def step(world, {:resolve, index, wanted}) do
    case pick_from(pending(world), index) do
      nil -> world
      {bid_id, bid} -> resolve_bid(world, bid_id, bid, wanted)
    end
  end

  def step(world, {:retry, index, extra}) do
    case pick_from(sorted_bids(world), index) do
      nil ->
        world

      {original, bid} ->
        command =
          Log.bid("retry", bid.user_id, bid.amount + extra, bid.idempotency_key)

        expected = if extra == 0, do: {:duplicate, original}, else: :key_reused
        {:error, ^expected} = decide(world, command)

        note(world, if(extra == 0, do: :repeat_same_amount, else: :repeat_changed_amount))
    end
  end

  def step(world, :close) do
    case decide(world, :close) do
      {:error, :not_due} ->
        world

      {:ok, events} ->
        world = append(world, events)
        note_if(world, world.state.closed.winner_bid_id != nil, :closed_with_winner)
    end
  end

  # A crash: everything after some event never happened. The server replays what
  # is left and carries on, re-authorizing whatever is pending. The provider
  # still remembers its answer for every bid the log still has.
  def step(world, {:crash, point}) do
    keep = 1 + rem(point, length(world.log))
    {log, lost} = Enum.split(world.log, keep)
    state = Auction.replay(log)

    world = %{
      world
      | log: log,
        state: state,
        provider: Map.take(world.provider, Map.keys(state.bids))
    }

    statuses = Enum.map(state.bids, fn {_id, bid} -> bid.status end)

    world
    |> note_if(:pending in statuses, :crash_with_bid_pending)
    |> note_if(:authorized in statuses, :crash_between_hold_and_outcome)
    |> note_if(
      Enum.any?(lost, &match?(%{data: %Event.AuctionClosed{}}, &1)),
      :crash_lost_the_close
    )
  end

  @doc "Bids with no outcome yet, oldest first: the authorizations in flight."
  def pending(world) do
    Enum.filter(sorted_bids(world), fn {_id, bid} -> bid.status in [:pending, :authorized] end)
  end

  def decide(world, command), do: Auction.decide(world.state, command, Log.at(world.now))

  # -- helpers ---------------------------------------------------------------

  defp resolve_bid(world, bid_id, bid, wanted) do
    {answer, provider} =
      case world.provider do
        %{^bid_id => answer} ->
          {answer, world.provider}

        _first_time ->
          answer = answer(wanted, bid_id, bid.amount)
          {answer, Map.put(world.provider, bid_id, answer)}
      end

    command = {:authorization, %{bid_id: bid_id, alias: "alias-#{bid.user_id}", result: answer}}
    closed? = world.state.closed != nil
    high = world.state.current_high

    world =
      %{world | provider: provider}
      |> note_if(world.now == @ends_ms, :result_at_ends_at)
      |> note_if(closed?, :result_after_close)
      |> command!(command)

    case world.state.bids[bid_id] do
      %{status: :accepted} ->
        world
        |> note(:accepted)
        |> note_if(world.now == @ends_ms - 1, :accepted_in_last_ms)

      %{status: :lost, reason: :below_minimum} ->
        note_if(world, high != nil and high.amount == bid.amount, :tie)

      %{status: :lost, reason: :not_covered} ->
        note(world, :not_covered)

      %{status: :rejected} ->
        note(world, :declined)

      _other ->
        world
    end
  end

  defp answer(:full, bid_id, amount), do: {:ok, "pi_#{bid_id}", amount}
  defp answer(:extra, bid_id, amount), do: {:ok, "pi_#{bid_id}", amount + 50}
  defp answer(:short, bid_id, amount), do: {:ok, "pi_#{bid_id}", amount - 1}
  defp answer({:fail, reason}, _bid_id, _amount), do: {:error, reason}

  defp resolve_amount(world, {:minimum_plus, offset}),
    do: max(1, current_minimum(world) + offset)

  defp resolve_amount(world, {:tie_with, index}) do
    case pick_from(pending(world), index) do
      nil -> current_minimum(world)
      {_id, bid} -> bid.amount
    end
  end

  # Once closed there is no minimum, but late bids still arrive.
  defp current_minimum(world), do: Auction.minimum_next_bid(world.state) || 500

  # Map order isn't something to depend on, so picks go through the seq order of
  # the ids.
  defp sorted_bids(world) do
    Enum.sort_by(world.state.bids, fn {"b" <> number, _bid} -> String.to_integer(number) end)
  end

  defp pick_from([], _index), do: nil
  defp pick_from(list, index), do: Enum.at(list, rem(index, length(list)))

  defp command!(world, command) do
    {:ok, events} = decide(world, command)
    append(world, events)
  end

  defp append(world, events) do
    {log, state} = Log.append(world.log, world.state, events, Log.at(world.now))
    %{world | log: log, state: state}
  end

  defp note(world, situation), do: %{world | seen: MapSet.put(world.seen, situation)}
  defp note_if(world, true, situation), do: note(world, situation)
  defp note_if(world, false, _situation), do: world
end
