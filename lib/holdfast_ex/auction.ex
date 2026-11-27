defmodule HoldfastEx.Auction do
  @moduledoc """
  The pure core (ADR 0004): no processes, database or clock.

  `decide/3` takes the state, a command and the time, and says which events
  should be appended. `apply/2` folds one appended event into the state. Nothing
  else changes state, so replaying a log rebuilds it exactly.
  """

  import Kernel, except: [apply: 2]

  alias HoldfastEx.Auction.State
  alias HoldfastEx.Event

  @max_duration_seconds 24 * 60 * 60

  @type authorization_result ::
          {:ok, payment_intent_id :: String.t(), amount_capturable :: non_neg_integer()}
          | {:error, :authentication_required | :processing_error | String.t()}

  @type command ::
          {:create,
           %{
             title: String.t(),
             starts_at: DateTime.t(),
             ends_at: DateTime.t(),
             starting_price: pos_integer(),
             min_increment: pos_integer()
           }}
          | {:place_bid,
             %{
               bid_id: String.t(),
               user_id: String.t(),
               amount: pos_integer(),
               idempotency_key: String.t()
             }}
          | {:authorization,
             %{bid_id: String.t(), alias: String.t(), result: authorization_result()}}
          | :close

  @type error ::
          :already_created
          | :invalid_auction
          | :not_found
          | :invalid_bid
          | {:duplicate, bid_id :: String.t()}
          | :key_reused
          | :bid_id_taken
          | :unknown_bid
          | :not_due

  @spec new() :: State.t()
  def new, do: %State{}

  @spec replay([Event.t()]) :: State.t()
  def replay(events), do: Enum.reduce(events, new(), &apply(&2, &1))

  @doc "The lowest amount a new bid can have, or nil once closed (spec §6)."
  @spec minimum_next_bid(State.t()) :: pos_integer() | nil
  def minimum_next_bid(%State{auction: nil}), do: nil
  def minimum_next_bid(%State{closed: %{}}), do: nil
  def minimum_next_bid(%State{current_high: nil, auction: auction}), do: auction.starting_price

  def minimum_next_bid(%State{current_high: high, auction: auction}),
    do: high.amount + auction.min_increment

  # -- decide ----------------------------------------------------------------

  @doc """
  The events a command produces, in append order. They are appended together.

  An empty list means the command has nothing left to do (a repeated close, or a
  late result for a resolved bid).
  """
  @spec decide(State.t(), command(), DateTime.t()) :: {:ok, [Event.t()]} | {:error, error()}
  def decide(%State{auction: nil}, {:create, params}, _now), do: create(params)
  def decide(%State{}, {:create, _params}, _now), do: {:error, :already_created}
  def decide(%State{auction: nil}, _command, _now), do: {:error, :not_found}
  def decide(state, {:place_bid, params}, now), do: place_bid(state, params, now)
  def decide(state, {:authorization, params}, now), do: authorization(state, params, now)
  def decide(state, :close, now), do: close(state, now)

  defp create(%{
         title: title,
         starts_at: starts_at,
         ends_at: ends_at,
         starting_price: starting_price,
         min_increment: min_increment
       }) do
    duration = DateTime.diff(ends_at, starts_at, :microsecond)

    if duration > 0 and duration <= @max_duration_seconds * 1_000_000 and
         positive_integer?(starting_price) and positive_integer?(min_increment) do
      ok([
        %Event.AuctionCreated{
          title: title,
          starts_at: starts_at,
          ends_at: ends_at,
          starting_price: starting_price,
          min_increment: min_increment
        }
      ])
    else
      {:error, :invalid_auction}
    end
  end

  defp place_bid(state, %{bid_id: bid_id, user_id: user_id, amount: amount} = params, now) do
    key = params.idempotency_key

    cond do
      not positive_integer?(amount) ->
        {:error, :invalid_bid}

      original = state.keys[{user_id, key}] ->
        repeated_key(state.bids[original], original, amount)

      Map.has_key?(state.bids, bid_id) ->
        {:error, :bid_id_taken}

      true ->
        placed = %Event.BidPlaced{
          bid_id: bid_id,
          user_id: user_id,
          amount: amount,
          idempotency_key: key
        }

        # A refused bid is still a bid: both events, and nobody is called (ADR 0014).
        case refusal(state, amount, now) do
          nil -> ok([placed])
          reason -> ok([placed, %Event.BidRejected{bid_id: bid_id, reason: reason}])
        end
    end
  end

  defp repeated_key(%{amount: amount}, bid_id, amount), do: {:error, {:duplicate, bid_id}}
  defp repeated_key(_bid, _bid_id, _amount), do: {:error, :key_reused}

  defp authorization(state, %{bid_id: bid_id, alias: bidder_alias, result: result}, now) do
    case state.bids[bid_id] do
      nil ->
        {:error, :unknown_bid}

      %{status: status} = bid when status in [:pending, :authorized] ->
        ok(resolve(state, bid_id, bid, result, bidder_alias, now))

      _resolved ->
        ok([])
    end
  end

  defp resolve(_state, bid_id, _bid, {:error, reason}, _alias, _now),
    do: [%Event.BidRejected{bid_id: bid_id, reason: reason}]

  # The hold is recorded before the decision (spec §5), in the same append.
  defp resolve(state, bid_id, %{status: :pending} = bid, {:ok, intent, capturable}, name, now) do
    held = %Event.HoldAuthorized{
      bid_id: bid_id,
      payment_intent_id: intent,
      amount_capturable: capturable
    }

    [held, outcome(state, bid_id, bid.amount, capturable, name, now)]
  end

  # The log already has this bid's hold (a restart between the two events). Decide
  # on what the log says, and don't record a second hold.
  defp resolve(state, bid_id, %{status: :authorized} = bid, {:ok, _, _}, name, now),
    do: [outcome(state, bid_id, bid.amount, bid.amount_capturable, name, now)]

  # Decided against the state as it is now, not as it was when the bid was placed.
  defp outcome(state, bid_id, amount, capturable, bidder_alias, now) do
    reason =
      cond do
        ended?(state, now) -> :ended
        not_open?(state, now) -> :not_open
        capturable < amount -> :not_covered
        amount < minimum_next_bid(state) -> :below_minimum
        true -> nil
      end

    if reason do
      %Event.BidLost{bid_id: bid_id, reason: reason}
    else
      %Event.BidAccepted{
        bid_id: bid_id,
        amount: amount,
        alias: bidder_alias,
        previous_high_bid_id: state.current_high && state.current_high.bid_id
      }
    end
  end

  defp close(%State{closed: %{}}, _now), do: ok([])

  defp close(state, now) do
    if DateTime.before?(now, state.auction.ends_at) do
      {:error, :not_due}
    else
      ok([%Event.AuctionClosed{winner_bid_id: state.current_high && state.current_high.bid_id}])
    end
  end

  # The pre-check: why a new bid can't count, before anyone spends a Stripe call.
  defp refusal(state, amount, now) do
    cond do
      ended?(state, now) -> :ended
      not_open?(state, now) -> :not_open
      amount < minimum_next_bid(state) -> :below_minimum
      true -> nil
    end
  end

  # At `ends_at` is already too late (invariant 3).
  defp ended?(%State{closed: %{}}, _now), do: true
  defp ended?(state, now), do: not DateTime.before?(now, state.auction.ends_at)

  defp not_open?(state, now), do: DateTime.before?(now, state.auction.starts_at)

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp ok(data), do: {:ok, Enum.map(data, &%Event{data: &1})}

  # -- apply -----------------------------------------------------------------

  @doc """
  Folds one appended event into the state. Its `seq` must be the next one: a gap
  or a repeat means the log and the state have parted, so it raises.
  """
  @spec apply(State.t(), Event.t()) :: State.t()
  def apply(%State{version: version} = state, %Event{seq: seq, data: data} = event)
      when seq == version + 1 do
    state = %{state | version: seq}
    state = if Event.public?(event), do: %{state | last_public_seq: seq}, else: state
    fold(state, data)
  end

  defp fold(state, %Event.AuctionCreated{} = created), do: %{state | auction: created}

  defp fold(state, %Event.BidPlaced{} = placed) do
    bid = %{
      user_id: placed.user_id,
      amount: placed.amount,
      idempotency_key: placed.idempotency_key,
      status: :pending,
      reason: nil,
      payment_intent_id: nil,
      amount_capturable: nil
    }

    %{
      state
      | bids: Map.put(state.bids, placed.bid_id, bid),
        keys: Map.put(state.keys, {placed.user_id, placed.idempotency_key}, placed.bid_id)
    }
  end

  defp fold(state, %Event.HoldAuthorized{} = held) do
    update_bid(state, held.bid_id, %{
      status: :authorized,
      payment_intent_id: held.payment_intent_id,
      amount_capturable: held.amount_capturable
    })
  end

  defp fold(state, %Event.BidRejected{bid_id: id, reason: reason}),
    do: update_bid(state, id, %{status: :rejected, reason: reason})

  defp fold(state, %Event.BidLost{bid_id: id, reason: reason}),
    do: update_bid(state, id, %{status: :lost, reason: reason})

  defp fold(state, %Event.BidAccepted{} = accepted) do
    state = update_bid(state, accepted.bid_id, %{status: :accepted})
    high = %{bid_id: accepted.bid_id, amount: accepted.amount, alias: accepted.alias}
    %{state | current_high: high}
  end

  defp fold(state, %Event.HoldReleased{payment_intent_id: intent}),
    do: %{state | released: MapSet.put(state.released, intent)}

  defp fold(state, %Event.AuctionClosed{winner_bid_id: winner}),
    do: %{state | closed: %{winner_bid_id: winner}}

  defp fold(state, %Event.CaptureSucceeded{}), do: %{state | capture: :succeeded}

  defp fold(state, %Event.CaptureFailed{reason: reason}),
    do: %{state | capture: {:failed, reason}}

  defp update_bid(state, bid_id, changes),
    do: %{state | bids: Map.update!(state.bids, bid_id, &Map.merge(&1, changes))}
end
