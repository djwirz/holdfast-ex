defmodule HoldfastEx.InvariantsTest do
  @moduledoc """
  A check that can't fail proves nothing, so each invariant is shown a log that
  breaks it. These logs are written by hand because the core won't produce them.
  """

  use ExUnit.Case, async: true

  alias HoldfastEx.Event
  alias HoldfastEx.Invariants
  alias HoldfastEx.Test.Log

  # Stamps seq in order; each entry is data, or {data, ms}.
  defp log(entries) do
    created = struct!(Event.AuctionCreated, Log.params())

    [created | entries]
    |> Enum.map(fn
      {data, ms} -> {data, ms}
      data -> {data, 2_000}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{data, ms}, seq} -> %Event{seq: seq, at: Log.at(ms), data: data} end)
  end

  defp placed(id, amount, user \\ "ann", key \\ nil),
    do: %Event.BidPlaced{
      bid_id: id,
      user_id: user,
      amount: amount,
      idempotency_key: key || "key-#{id}"
    }

  defp held(id, amount, intent \\ nil),
    do: %Event.HoldAuthorized{
      bid_id: id,
      payment_intent_id: intent || "pi_#{id}",
      amount_capturable: amount
    }

  defp accepted(id, amount, previous \\ nil),
    do: %Event.BidAccepted{
      bid_id: id,
      amount: amount,
      alias: "a",
      previous_high_bid_id: previous
    }

  defp closed(winner), do: %Event.AuctionClosed{winner_bid_id: winner}

  defp broken(events), do: events |> Invariants.check() |> Enum.map(& &1.invariant) |> Enum.uniq()

  defp good do
    [
      placed("b1", 500),
      held("b1", 500),
      accepted("b1", 500),
      placed("b2", 600, "bob"),
      held("b2", 600),
      accepted("b2", 600, "b1")
    ]
  end

  test "a good log breaks nothing" do
    assert Invariants.check(log(good() ++ [{closed("b2"), 61_000}])) == []
  end

  test "1: accepted with no hold, a hold that's too small, or one that came after" do
    assert broken(log([placed("b1", 500), accepted("b1", 500)])) == [1]
    assert broken(log([placed("b1", 500), held("b1", 499), accepted("b1", 500)])) == [1]
    assert broken(log([placed("b1", 500), accepted("b1", 500), held("b1", 500)])) == [1]
  end

  test "2: below the start, too small a rise, wrong chain or wrong winner" do
    low = [placed("b1", 499), held("b1", 499), accepted("b1", 499)]
    assert broken(log(low)) == [2]

    small = [placed("b3", 699), held("b3", 699), accepted("b3", 699, "b2")]
    assert broken(log(good() ++ small)) == [2]

    chain = [placed("b3", 700), held("b3", 700), accepted("b3", 700, "b1")]
    assert broken(log(good() ++ chain)) == [2]

    assert broken(log(good() ++ [{closed("b1"), 61_000}])) == [2]
    assert broken(log(good() ++ [{closed(nil), 61_000}])) == [2]

    changed = [placed("b1", 500), held("b1", 900), accepted("b1", 900)]
    assert broken(log(changed)) == [2]
  end

  test "3: accepted at ends_at, accepted after the close, or closed twice" do
    at_end = [placed("b1", 500), held("b1", 500), {accepted("b1", 500), 61_000}]
    assert broken(log(at_end)) == [3]

    after_close = [
      placed("b1", 500),
      {closed(nil), 61_000},
      held("b1", 500),
      accepted("b1", 500)
    ]

    assert broken(log(after_close)) == [3]
    assert broken(log([{closed(nil), 61_000}, {closed(nil), 62_000}])) == [3]
  end

  test "5: a key used twice, a second hold, a reused intent or a second outcome" do
    assert broken(log([placed("b1", 500, "ann", "k"), placed("b2", 500, "ann", "k")])) == [5]
    assert broken(log([placed("b1", 500, "ann", "k"), placed("b2", 500, "bob", "k")])) == []
    assert broken(log([placed("b1", 500), held("b1", 500), held("b1", 500, "pi_2")])) == [5]

    shared = [
      placed("b1", 500),
      placed("b2", 500),
      held("b1", 500, "pi"),
      held("b2", 500, "pi")
    ]

    assert broken(log(shared)) == [5]

    twice = [placed("b1", 500), %Event.BidRejected{bid_id: "b1", reason: :ended}]
    assert broken(log(twice ++ [%Event.BidLost{bid_id: "b1", reason: :ended}])) == [5]
  end

  test "4: only the current high's hold may live, then the winner's until captured" do
    open = log(good())
    assert Invariants.no_orphaned_holds(open, ["pi_b2"]) == []
    assert [%{invariant: 4}] = Invariants.no_orphaned_holds(open, ["pi_b1", "pi_b2"])

    unsettled = log(good() ++ [{closed("b2"), 61_000}])
    assert Invariants.no_orphaned_holds(unsettled, ["pi_b2"]) == []

    captured = %Event.CaptureSucceeded{payment_intent_id: "pi_b2"}
    settled = log(good() ++ [{closed("b2"), 61_000}, {captured, 62_000}])
    assert Invariants.no_orphaned_holds(settled, []) == []
    assert [%{invariant: 4}] = Invariants.no_orphaned_holds(settled, ["pi_b2"])

    assert [%{invariant: 4}] = Invariants.no_orphaned_holds(log([]), ["pi_unknown"])
  end
end
