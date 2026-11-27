defmodule HoldfastEx.SecondWriterTest do
  @moduledoc "Two writers for one auction (ADR 0005): one of them must lose."
  use HoldfastEx.Test.DBCase, async: false

  alias HoldfastEx.AuctionServer

  @moduletag capture_log: true

  # A server outside the registry, as on a node that isn't clustered with ours.
  defp second_writer(id) do
    pid = start_supervised!({AuctionServer, auction_id: id, name: nil}, restart: :temporary)
    _ = :sys.get_state(pid)
    pid
  end

  defp call(pid, bid_id, user, amount) do
    params = %{bid_id: bid_id, user_id: user, amount: amount, idempotency_key: "key-#{bid_id}"}
    GenServer.call(pid, {:place_bid, params, 1_000})
  end

  test "a stale writer loses its seq, and its caller hears nothing" do
    id = open_auction()
    stale = second_writer(id)
    monitor = Process.monitor(stale)
    {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("ann", 500))
    log = EventStore.load(id)

    assert {:conflict, _} = catch_exit(call(stale, "late", "bob", 500))

    assert_receive {:DOWN, ^monitor, :process, ^stale, :conflict}
    assert EventStore.load(id) == log
    assert EventStore.lookup_key("bob", "key-late") == nil
    assert_consistent(id)
  end

  test "both deciding one bid: it is accepted once, on one hold" do
    id = open_auction()
    Memory.pause()

    {:ok, %{id: bid_id}} = Auctions.place_bid(id, offer("ann", 500), deadline_ms: 20)
    first = server(id)
    second = second_writer(id)
    eventually(fn -> Memory.calls(bid_id) == 2 end)
    monitors = Map.new([first, second], &{Process.monitor(&1), &1})

    Memory.release()

    # Whichever appends second dies.
    assert_receive {:DOWN, ref, :process, loser, :conflict}
    assert monitors[ref] == loser
    eventually(fn -> Auctions.get_bid(id, bid_id).status == :accepted end)
    assert count(id, Event.BidAccepted) == 1
    assert count(id, Event.HoldAuthorized) == 1
    assert map_size(Memory.holds()) == 1
    assert_consistent(id)
  end

  test "a caller whose server turns out to be stale still gets its bid placed" do
    id = open_auction()
    stale = server(id)
    # Another writer gets ahead of the registered server.
    other = second_writer(id)
    assert {:ok, %{status: status}} = call(other, "b1", "ann", 500)
    assert status in [:accepted, :pending]
    eventually(fn -> count(id, Event.BidAccepted) == 1 end)

    assert {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("bob", 600))

    assert server(id) != stale
    assert_consistent(id)
  end

  test "a used key it didn't know about, for its own auction, means it is stale" do
    id = open_auction()
    stale = second_writer(id)
    monitor = Process.monitor(stale)
    {:ok, _} = Auctions.place_bid(id, offer("ann", 500, "k"))

    params = %{bid_id: "again", user_id: "ann", amount: 500, idempotency_key: "k"}
    assert {:conflict, _} = catch_exit(GenServer.call(stale, {:place_bid, params, 1_000}))
    assert_receive {:DOWN, ^monitor, :process, ^stale, :conflict}
  end
end
