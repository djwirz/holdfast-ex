defmodule HoldfastEx.Invariants do
  @moduledoc """
  The invariants of spec §7, as functions over one auction's appended events.

  The property tests use these now; the integration tests and the storm's checker
  will. They deliberately read raw events and never call `HoldfastEx.Auction`, so
  a broken rule there can't also break the check of it.

  Each function returns the violations it finds; `[]` means it holds.
  """

  alias HoldfastEx.Event

  @type violation :: %{invariant: 1..5, seq: pos_integer() | nil, message: String.t()}

  @doc """
  Invariants 1, 2, 3 and 5. Invariant 4 also needs the payment provider's live
  holds: see `no_orphaned_holds/2`.
  """
  @spec check([Event.t()]) :: [violation()]
  def check(events),
    do: covered(events) ++ ordered(events) ++ closed_is_closed(events) ++ idempotent(events)

  @doc "1. Every accepted bid is preceded by a hold for it, at least as large as the bid."
  @spec covered([Event.t()]) :: [violation()]
  def covered(events) do
    {_amounts, _holds, violations} =
      Enum.reduce(events, {%{}, %{}, []}, fn
        %{data: %Event.BidPlaced{} = placed}, {amounts, holds, found} ->
          {Map.put(amounts, placed.bid_id, placed.amount), holds, found}

        %{data: %Event.HoldAuthorized{} = held}, {amounts, holds, found} ->
          {amounts, Map.put(holds, held.bid_id, held.amount_capturable), found}

        %{data: %Event.BidAccepted{} = accepted} = event, {amounts, holds, found} ->
          held = holds[accepted.bid_id]
          bid = max(accepted.amount, Map.get(amounts, accepted.bid_id, 0))

          if held && held >= bid do
            {amounts, holds, found}
          else
            message = "bid #{accepted.bid_id} accepted for #{bid} with a hold of #{inspect(held)}"
            {amounts, holds, [violation(1, event, message) | found]}
          end

        _event, acc ->
          acc
      end)

    Enum.reverse(violations)
  end

  @doc """
  2. Accepted bids start at or above the starting price and rise by at least the
  increment, each naming the one before it, so exactly one is the current high.
  The winner at close is that one.
  """
  @spec ordered([Event.t()]) :: [violation()]
  def ordered(events) do
    initial = %{auction: nil, amounts: %{}, high: nil, accepted: MapSet.new(), found: []}

    events
    |> Enum.reduce(initial, &ordered_step/2)
    |> Map.fetch!(:found)
    |> Enum.reverse()
  end

  defp ordered_step(%{data: %Event.AuctionCreated{} = created}, acc),
    do: %{acc | auction: created}

  defp ordered_step(%{data: %Event.BidPlaced{} = placed}, acc),
    do: %{acc | amounts: Map.put(acc.amounts, placed.bid_id, placed.amount)}

  defp ordered_step(%{data: %Event.BidAccepted{} = accepted} = event, acc) do
    floor =
      case acc.high do
        nil -> acc.auction.starting_price
        {_id, amount} -> amount + acc.auction.min_increment
      end

    previous = acc.high && elem(acc.high, 0)

    problems =
      [
        accepted.amount < floor && "accepted #{accepted.amount}, below #{floor}",
        accepted.amount != acc.amounts[accepted.bid_id] && "accepted amount differs from the bid",
        accepted.previous_high_bid_id != previous &&
          "previous high should be #{inspect(previous)}",
        MapSet.member?(acc.accepted, accepted.bid_id) && "bid #{accepted.bid_id} accepted twice"
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&violation(2, event, &1))

    %{
      acc
      | high: {accepted.bid_id, accepted.amount},
        accepted: MapSet.put(acc.accepted, accepted.bid_id),
        found: Enum.reverse(problems, acc.found)
    }
  end

  defp ordered_step(%{data: %Event.AuctionClosed{winner_bid_id: winner}} = event, acc) do
    high = acc.high && elem(acc.high, 0)

    if winner == high do
      acc
    else
      message = "winner is #{inspect(winner)}, current high is #{inspect(high)}"
      %{acc | found: [violation(2, event, message) | acc.found]}
    end
  end

  defp ordered_step(_event, acc), do: acc

  @doc """
  3. No bid is accepted at or after `ends_at` by the event's own time, and none
  after the auction closed. It closes once.
  """
  @spec closed_is_closed([Event.t()]) :: [violation()]
  def closed_is_closed(events) do
    {_ends_at, _closed?, violations} =
      Enum.reduce(events, {nil, false, []}, fn
        %{data: %Event.AuctionCreated{ends_at: ends_at}}, {_, closed?, found} ->
          {ends_at, closed?, found}

        %{data: %Event.BidAccepted{}} = event, {ends_at, closed?, found} ->
          late = not DateTime.before?(event.at, ends_at)

          found =
            cond do
              late -> [violation(3, event, "accepted at #{event.at}, ends #{ends_at}") | found]
              closed? -> [violation(3, event, "accepted after the close") | found]
              true -> found
            end

          {ends_at, closed?, found}

        %{data: %Event.AuctionClosed{}} = event, {ends_at, true, found} ->
          {ends_at, true, [violation(3, event, "closed twice") | found]}

        %{data: %Event.AuctionClosed{}}, {ends_at, false, found} ->
          {ends_at, true, found}

        _event, acc ->
          acc
      end)

    Enum.reverse(violations)
  end

  @doc """
  4. Once everything is idle, the only live holds are the current high's (open)
  or the winner's (closed, until captured). `live` is the payment intent ids the
  provider still holds. Only meaningful when nothing is in flight, and nothing
  releases holds before slice 4.
  """
  @spec no_orphaned_holds([Event.t()], Enumerable.t(String.t())) :: [violation()]
  def no_orphaned_holds(events, live) do
    initial = %{intents: %{}, high: nil, captured?: false}

    final =
      Enum.reduce(events, initial, fn
        %{data: %Event.HoldAuthorized{} = held}, acc ->
          %{acc | intents: Map.put(acc.intents, held.bid_id, held.payment_intent_id)}

        # The winner is the last accepted bid (invariant 2), so this covers both.
        %{data: %Event.BidAccepted{bid_id: id}}, acc ->
          %{acc | high: id}

        %{data: %Event.CaptureSucceeded{}}, acc ->
          %{acc | captured?: true}

        _event, acc ->
          acc
      end)

    wanted = if final.captured?, do: nil, else: final.intents[final.high]

    for intent <- live, intent != wanted do
      %{invariant: 4, seq: nil, message: "orphaned hold #{intent}"}
    end
  end

  @doc """
  5. A user's key makes one bid, and a bid gets one hold and one outcome.
  """
  @spec idempotent([Event.t()]) :: [violation()]
  def idempotent(events) do
    {_seen, violations} =
      Enum.reduce(events, {MapSet.new(), []}, fn event, {seen, found} ->
        claims = claims(event.data)
        repeats = Enum.filter(claims, &MapSet.member?(seen, &1))
        new = Enum.map(repeats, &violation(5, event, "second #{inspect(&1)}"))

        {Enum.into(claims, seen), Enum.reverse(new, found)}
      end)

    Enum.reverse(violations)
  end

  # What each event may be the only one to claim.
  defp claims(%Event.BidPlaced{} = placed),
    do: [{:key, placed.user_id, placed.idempotency_key}, {:bid, placed.bid_id}]

  defp claims(%Event.HoldAuthorized{} = held),
    do: [{:hold_for_bid, held.bid_id}, {:payment_intent, held.payment_intent_id}]

  defp claims(%Event.BidAccepted{bid_id: id}), do: [{:outcome, id}]
  defp claims(%Event.BidRejected{bid_id: id}), do: [{:outcome, id}]
  defp claims(%Event.BidLost{bid_id: id}), do: [{:outcome, id}]
  defp claims(_data), do: []

  defp violation(invariant, event, message),
    do: %{invariant: invariant, seq: event.seq, message: message}
end
