defmodule HoldfastEx.PublicViewTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias HoldfastEx.Auction
  alias HoldfastEx.Event
  alias HoldfastEx.PublicView
  alias HoldfastEx.Test.Log
  alias HoldfastEx.Test.World

  property "the public view agrees with the core, however the log is read" do
    check all(
            start <- World.start_ms(),
            actions <- World.actions(),
            cut <- integer(0..200),
            max_runs: 300
          ) do
      log = Enum.reduce(actions, World.new(start), &World.step(&2, &1)).log
      core = Auction.replay(log)
      {view, published} = PublicView.fold(PublicView.new("a"), log)

      # In two pieces, as the server folds it.
      {head, tail} = Enum.split(log, rem(cut, length(log) + 1))
      {partway, first} = PublicView.fold(PublicView.new("a"), head)
      assert PublicView.fold(partway, tail) == {view, Enum.drop(published, length(first))}

      # From the public types only, as a read does.
      public_types = [
        Event.AuctionCreated,
        Event.BidAccepted,
        Event.AuctionClosed,
        Event.CaptureSucceeded
      ]

      filtered = Enum.filter(log, &(&1.data.__struct__ in public_types))
      assert {_, ^published} = PublicView.fold(PublicView.new("a"), filtered)

      assert view.version == core.version
      assert view.last_public_seq == core.last_public_seq

      snapshot = PublicView.snapshot(view, Log.at(0), nil)
      assert snapshot.auction.minimumNextBid == Auction.minimum_next_bid(core)

      # Each previous public seq is the one before (ADR 0013).
      versions = Enum.map(published, fn {_, event} -> event.version end)
      assert Enum.map(published, &elem(&1, 0)) == Enum.drop([0 | versions], -1)

      for {bid_id, bid} <- core.bids do
        shown = PublicView.bid(log, "a", bid_id)
        assert shown.amount == bid.amount

        expected =
          case bid.status do
            status when status in [:pending, :authorized] -> "pending"
            :rejected -> "rejected"
            :lost -> "lost_race"
            :accepted -> accepted_status(core, bid_id)
          end

        assert shown.status == expected
        assert is_nil(shown.resolvedAt) == (shown.status == "pending")
      end
    end
  end

  defp accepted_status(core, bid_id) do
    cond do
      core.current_high.bid_id != bid_id -> "outbid"
      core.closed -> "won"
      true -> "accepted"
    end
  end

  test "nil for a bid the events don't hold" do
    {log, _} = Log.created()
    assert PublicView.bid(log, "a", "nope") == nil
  end

  test "settled once captured, though the close event still says closed" do
    {log, _} =
      Log.created()
      |> Log.run(Log.bid("b1", "ann", 500), Log.at(2_000))
      |> Log.run(Log.authorized("b1", 500), Log.at(2_100))
      |> Log.run(:close, Log.at(61_000))

    captured = %Event{
      seq: length(log) + 1,
      at: Log.at(61_100),
      data: %Event.CaptureSucceeded{payment_intent_id: "pi_b1"}
    }

    {view, published} = PublicView.fold(PublicView.new("a"), log ++ [captured])

    assert PublicView.snapshot(view, Log.at(0), nil).auction.status == "settled"
    assert {_, %{type: "auction.closed", status: "closed"}} = List.last(published)
  end
end
