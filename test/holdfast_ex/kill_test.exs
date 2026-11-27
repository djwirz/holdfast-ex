defmodule HoldfastEx.KillTest do
  @moduledoc "The server killed at every step, then restarted by its supervisor."
  use HoldfastEx.Test.DBCase, async: false

  @moduletag capture_log: true

  for step <- [
        :bid_received,
        :bid_placed,
        :authorize_started,
        :authorization_received,
        :outcome_appended,
        :replied
      ] do
    test "killed at #{step}: one bid, one hold, one outcome" do
      id = open_auction()
      first = server(id)
      monitor = Process.monitor(first)
      kill_at(id, unquote(step))

      assert {:ok, answered} = Auctions.place_bid(id, offer("ann", 500, "k"))
      assert_receive {:DOWN, ^monitor, :process, ^first, :killed}

      # The client's retry of its own key.
      assert {:ok, retried} = Auctions.place_bid(id, offer("ann", 500, "k"))
      assert retried.id == answered.id
      assert retried.status == :accepted

      assert count(id, Event.BidPlaced) == 1
      assert count(id, Event.HoldAuthorized) == 1
      assert count(id, Event.BidAccepted) == 1
      assert Map.keys(Memory.holds()) == [answered.id]
      assert server(id) != first
      assert_consistent(id)
    end
  end

  test "killed while the provider holds the money and hasn't answered" do
    id = open_auction()
    first = server(id)
    Memory.pause()

    assert {:ok, %{status: :pending, id: bid_id}} =
             Auctions.place_bid(id, offer("ann", 500), deadline_ms: 20)

    assert Map.has_key?(Memory.holds(), bid_id)
    Process.exit(first, :kill)

    # The new server asks again with the same bid id.
    eventually(fn -> Memory.calls(bid_id) == 2 end)
    Memory.release()
    eventually(fn -> Auctions.get_bid(id, bid_id).status == :accepted end)

    assert map_size(Memory.holds()) == 1
    assert_consistent(id)
  end

  test "killed again while replaying" do
    id = open_auction()
    first = server(id)
    kill_at(id, :replayed)
    Process.exit(first, :kill)

    eventually(fn -> Auctions.whereis(id) not in [nil, first] end)
    assert {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("ann", 500))
    assert_consistent(id)
  end

  for step <- [:close_due, :closed] do
    test "killed at #{step}: closes exactly once" do
      kill = unquote(step)
      id = Ecto.UUID.generate()
      kill_at(id, kill)
      created = struct!(Event.AuctionCreated, params(100))
      {:ok, _} = EventStore.append(id, 1, [%Event{data: created}])
      :ok = Auctions.ensure_started(id)

      eventually(fn -> count(id, Event.AuctionClosed) == 1 end)
      # Give a second close the chance it must not take.
      eventually(fn -> Auctions.whereis(id) end)
      Process.sleep(50)
      assert count(id, Event.AuctionClosed) == 1
      assert_consistent(id)
    end
  end
end
