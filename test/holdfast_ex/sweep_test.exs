defmodule HoldfastEx.SweepTest do
  use HoldfastEx.Test.DBCase, async: false

  alias HoldfastEx.Repo
  alias HoldfastEx.Sweep

  @moduletag capture_log: true

  test "an auction with no bids closes after a restart" do
    id = open_auction(150)
    server(id)
    # The node goes away before the close.
    stop_auctions()
    Process.sleep(200)
    assert count(id, Event.AuctionClosed) == 0

    start_supervised!({Sweep, interval_ms: 50})

    eventually(fn -> count(id, Event.AuctionClosed) == 1 end)
    assert_consistent(id)
  end

  test "a closed auction with a bid still unresolved is started again (ADR 0015)" do
    id = open_auction(200)
    Memory.pause()
    {:ok, %{id: bid_id}} = Auctions.place_bid(id, offer("ann", 500), deadline_ms: 20)
    eventually(fn -> count(id, Event.AuctionClosed) == 1 end)
    # Closed with no winner, and the node goes away with the bid in flight.
    stop_auctions()
    Memory.release()

    :ok = Sweep.run()

    eventually(fn -> Auctions.get_bid(id, bid_id).status == :lost end)
    assert_consistent(id)
  end

  test "a finished auction's server stops when idle, and a late bid brings it back" do
    id = open_auction(100, idle_timeout_ms: 50)
    [{supervisor, _}] = Registry.lookup(HoldfastEx.Registry, {:supervisor, id})
    monitor = Process.monitor(supervisor)

    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 2_000
    assert count(id, Event.AuctionClosed) == 1

    :ok = Sweep.run()
    assert Auctions.whereis(id) == nil

    assert {:ok, %{status: :rejected, reason: :ended}} =
             Auctions.place_bid(id, offer("ann", 500))

    assert_consistent(id)
  end

  test "neither an open auction nor one with a winner to capture idles out" do
    open = open_auction(60_000, idle_timeout_ms: 20)
    won = open_auction(300, idle_timeout_ms: 20)
    {:ok, %{status: :accepted}} = Auctions.place_bid(won, offer("ann", 500))
    servers = [server(open), server(won)]
    eventually(fn -> count(won, Event.AuctionClosed) == 1 end)
    Process.sleep(80)

    assert Enum.all?(servers, &Process.alive?/1)
  end

  test "a database error is logged, not crashed on" do
    {:ok, nowhere} =
      Repo.start_link(
        name: nil,
        url: "ecto://nobody:nothing@localhost:1/none",
        pool_size: 1,
        queue_target: 20,
        queue_interval: 40
      )

    real = Repo.put_dynamic_repo(nowhere)
    log = ExUnit.CaptureLog.capture_log(fn -> assert Sweep.run() == :ok end)
    Repo.put_dynamic_repo(real)
    Supervisor.stop(nowhere)

    assert log =~ "sweep failed"
  end
end
