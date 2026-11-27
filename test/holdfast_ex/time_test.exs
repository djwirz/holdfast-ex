defmodule HoldfastEx.TimeTest do
  @moduledoc "Bids around `ends_at`, wrong node clocks, and the close timer."
  use HoldfastEx.Test.DBCase, async: false

  @moduletag capture_log: true

  defp skewed(ms), do: [now: fn -> DateTime.add(DateTime.utc_now(), ms, :millisecond) end]

  test "accepted before the end, refused after it, and closed by the timer" do
    id = open_auction(400)
    assert {:ok, %{status: :accepted, id: winner}} = Auctions.place_bid(id, offer("ann", 500))

    eventually(fn -> count(id, Event.AuctionClosed) == 1 end)

    assert {:ok, %{status: :rejected, reason: :ended}} =
             Auctions.place_bid(id, offer("bob", 600))

    assert %Event.AuctionClosed{winner_bid_id: ^winner} =
             Enum.find(data(id), &is_struct(&1, Event.AuctionClosed))

    assert_consistent(id)
  end

  test "a slow node clock can't accept a late bid: the database refuses it" do
    id = open_auction(100, skewed(-60_000))
    ends_at = :sys.get_state(server(id)).core.auction.ends_at
    eventually(fn -> DateTime.after?(DateTime.utc_now(), ends_at) end)

    assert {:ok, %{status: :lost, reason: :ended}} = Auctions.place_bid(id, offer("ann", 500))

    assert count(id, Event.BidAccepted) == 0
    assert count(id, Event.HoldAuthorized) == 1
    assert_consistent(id)
  end

  test "a bid authorized across `ends_at` on a slow clock is lost" do
    id = open_auction(300, skewed(-60_000))
    Memory.pause()
    {:ok, %{id: bid_id}} = Auctions.place_bid(id, offer("ann", 500), deadline_ms: 20)
    ends_at = :sys.get_state(server(id)).core.auction.ends_at
    eventually(fn -> DateTime.after?(DateTime.utc_now(), ends_at) end)

    Memory.release()

    eventually(fn -> Auctions.get_bid(id, bid_id).status == :lost end)
    assert_consistent(id)
  end

  test "a fast node clock refuses early, and never accepts late" do
    id = open_auction(30_000, skewed(60_000))

    assert {:ok, %{status: :rejected, reason: :ended}} =
             Auctions.place_bid(id, offer("ann", 500))

    assert_consistent(id)
  end

  test "a close that fires early waits" do
    id = open_auction()
    pid = server(id)
    send(pid, :close)
    _ = :sys.get_state(pid)

    assert count(id, Event.AuctionClosed) == 0
    assert Process.alive?(pid)
  end

  test "bids in flight at the close lose, and the winner is whoever was accepted" do
    id = open_auction(500)
    {:ok, %{id: winner, status: :accepted}} = Auctions.place_bid(id, offer("ann", 500))
    Memory.pause()

    {:ok, %{id: late, status: :pending}} =
      Auctions.place_bid(id, offer("bob", 600), deadline_ms: 20)

    eventually(fn -> count(id, Event.AuctionClosed) == 1 end)
    Memory.release()
    eventually(fn -> Auctions.get_bid(id, late).status == :lost end)

    assert Auctions.get_bid(id, late).reason == :ended
    assert %{winner_bid_id: ^winner} = :sys.get_state(server(id)).core.closed
    assert_consistent(id)
  end
end
