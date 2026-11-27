defmodule HoldfastEx.Test.Log do
  @moduledoc """
  The smallest possible event store: it stamps each event with the next `seq` and
  a time, and folds it. `at` is the time the decision was made with, which assumes
  no clock skew. Slice 2 replaces this with Postgres and database time.
  """

  alias HoldfastEx.Auction
  alias HoldfastEx.Event

  @t0 ~U[2026-01-01 00:00:00.000000Z]

  def t0, do: @t0

  @doc "A time that many milliseconds after `t0/0`."
  def at(ms), do: DateTime.add(@t0, ms, :millisecond)

  def append(log, state, events, now) do
    Enum.reduce(events, {log, state}, fn %Event{} = event, {log, state} ->
      stamped = %Event{event | seq: state.version + 1, at: now}
      {log ++ [stamped], Auction.apply(state, stamped)}
    end)
  end

  @doc "Runs a command that must succeed and appends what it decides."
  def run({log, state}, command, now) do
    {:ok, events} = Auction.decide(state, command, now)
    append(log, state, events, now)
  end

  @doc "A log holding one auction: opens at 1,000 ms, ends at 61,000 ms, 500 + 100."
  def created do
    run({[], Auction.new()}, {:create, params()}, @t0)
  end

  def params do
    %{
      title: "A synthetic lamp",
      starts_at: at(1_000),
      ends_at: at(61_000),
      starting_price: 500,
      min_increment: 100
    }
  end

  def bid(bid_id, user_id, amount, key \\ nil) do
    {:place_bid,
     %{bid_id: bid_id, user_id: user_id, amount: amount, idempotency_key: key || "key-#{bid_id}"}}
  end

  def authorized(bid_id, capturable) do
    {:authorization,
     %{bid_id: bid_id, alias: "alias-#{bid_id}", result: {:ok, "pi_#{bid_id}", capturable}}}
  end

  def failed(bid_id, reason) do
    {:authorization, %{bid_id: bid_id, alias: "alias-#{bid_id}", result: {:error, reason}}}
  end
end
