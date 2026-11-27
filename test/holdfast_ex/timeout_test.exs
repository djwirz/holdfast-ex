defmodule HoldfastEx.TimeoutTest do
  @moduledoc """
  A bid call that gives up on its server before or after `bid_placed` commits
  (Q-A1), and what OTP does with the reply that comes too late (Q-V2). A server
  that dies at those two points is in `HoldfastEx.KillTest`.
  """
  use HoldfastEx.Test.DBCase, async: false

  alias HoldfastEx.Repo

  @moduletag capture_log: true

  @impatient [deadline_ms: 30, call_margin_ms: 30]

  test "gives up before the commit: unavailable, never `pending` for an unwritten bid" do
    id = open_auction()
    pause_at(id, :bid_received)

    assert Auctions.place_bid(id, offer("ann", 500, "k"), @impatient) == {:error, :unavailable}
    assert count(id, Event.BidPlaced) == 0

    assert_received {:paused, server}
    resume(server)

    # The abandoned call and its retries are still in the mailbox. One bid.
    assert {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("ann", 500, "k"))
    assert count(id, Event.BidPlaced) == 1
    assert map_size(Memory.holds()) == 1
    assert_consistent(id)
  end

  test "gives up before the commit, then the retry gets through" do
    id = open_auction()
    pause_at(id, :bid_received)

    task =
      Task.async(fn ->
        Auctions.place_bid(id, offer("ann", 500), deadline_ms: 100, call_margin_ms: 50)
      end)

    assert_receive {:paused, server}
    # Past the first call's timeout, inside the retries.
    Process.sleep(220)
    resume(server)

    assert {:ok, %{status: status}} = Task.await(task)
    assert status in [:accepted, :pending]
    assert count(id, Event.BidPlaced) == 1
  end

  test "gives up after the commit: answers with the bid in the log" do
    id = open_auction()
    pause_at(id, :bid_placed)

    assert {:ok, %{status: :pending, id: bid_id}} =
             Auctions.place_bid(id, offer("ann", 500), @impatient)

    assert_received {:paused, server}
    resume(server)
    eventually(fn -> Auctions.get_bid(id, bid_id).status == :accepted end)
    assert_consistent(id)
  end

  test "a reply after the caller gave up never reaches its mailbox" do
    id = open_auction()
    pause_at(id, :bid_received)
    server = server(id)
    params = Map.put(offer("ann", 500), :bid_id, "b1")

    assert {:timeout, _} = catch_exit(GenServer.call(server, {:place_bid, params, 1_000}, 30))

    assert_received {:paused, ^server}
    resume(server)
    eventually(fn -> count(id, Event.BidAccepted) == 1 end)
    _ = :sys.get_state(server)

    # The server did reply. The runtime dropped it with the call's alias.
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "database unreachable: unavailable, not a crash" do
    id = open_auction()
    pause_at(id, :bid_received)
    # This process now talks to nothing. The server still has the real database.
    {:ok, nowhere} =
      Repo.start_link(
        name: nil,
        url: "ecto://nobody:nothing@localhost:1/none",
        pool_size: 1,
        queue_target: 20,
        queue_interval: 40
      )

    real = Repo.put_dynamic_repo(nowhere)

    assert Auctions.place_bid(id, offer("ann", 500), @impatient) == {:error, :unavailable}
    # And for an auction with no server, where even looking it up fails.
    assert Auctions.place_bid(Ecto.UUID.generate(), offer("ann", 500)) == {:error, :unavailable}

    Repo.put_dynamic_repo(real)
    Supervisor.stop(nowhere)
    assert_received {:paused, server}
    resume(server)
  end
end
