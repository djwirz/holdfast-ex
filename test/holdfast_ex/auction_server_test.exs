defmodule HoldfastEx.AuctionServerTest do
  use HoldfastEx.Test.DBCase, async: false

  @moduletag capture_log: true

  test "accepts, refuses and records, through the log" do
    id = open_auction()

    assert {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("ann", 500))

    assert {:ok, %{status: :rejected, reason: :below_minimum}} =
             Auctions.place_bid(id, offer("bob", 550))

    assert {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer("bob", 600))
    assert Memory.holds() |> map_size() == 2
    assert_consistent(id)
  end

  test "a retry of a key gets its bid back, and a changed one is refused" do
    id = open_auction()
    other = open_auction()
    {:ok, bid} = Auctions.place_bid(id, offer("ann", 500, "k"))

    assert Auctions.place_bid(id, offer("ann", 500, "k")) == {:ok, bid}
    assert Auctions.place_bid(id, offer("ann", 700, "k")) == {:error, :key_reused}
    assert Auctions.place_bid(other, offer("ann", 500, "k")) == {:error, :key_reused}
    assert count(id, Event.BidPlaced) == 1
    assert count(other, Event.BidPlaced) == 0
    # A used key isn't a reason to restart anyone.
    assert Process.alive?(server(other))
  end

  test "says so for an auction that doesn't exist, and for a nonsense amount" do
    assert Auctions.place_bid(Ecto.UUID.generate(), offer("ann", 500)) == {:error, :not_found}
    assert Auctions.place_bid("not-a-uuid", offer("ann", 500)) == {:error, :not_found}
    assert Auctions.place_bid(open_auction(), offer("ann", 0)) == {:error, :invalid_bid}
    assert Auctions.create(%{params() | starting_price: 0}) == {:error, :invalid_auction}
  end

  test "a slow card gets `pending` at the deadline, and the bid still resolves" do
    id = open_auction()
    Memory.pause()

    assert {:ok, %{status: :pending, id: bid_id}} =
             Auctions.place_bid(id, offer("ann", 500), deadline_ms: 50)

    Memory.release()
    eventually(fn -> Auctions.get_bid(id, bid_id).status == :accepted end)
    assert_consistent(id)
  end

  test "everyone waiting on one bid is answered when it resolves" do
    id = open_auction()
    Memory.pause()
    place = fn -> Auctions.place_bid(id, offer("ann", 500, "k"), deadline_ms: 5_000) end
    first = Task.async(place)
    [bid_id] = eventually(fn -> Memory.waiting() != [] && Memory.waiting() end)
    second = Task.async(place)
    eventually(fn -> length(Map.get(:sys.get_state(server(id)).waiters, bid_id, [])) == 2 end)

    Memory.release()

    assert {:ok, %{status: :accepted, id: ^bid_id}} = Task.await(first)
    assert {:ok, %{status: :accepted, id: ^bid_id}} = Task.await(second)
    assert Memory.calls(bid_id) == 1
  end

  test "a declined card rejects the bid" do
    id = open_auction()
    Memory.script(fn _request, _attempt -> {:decline, "card_declined"} end)

    assert {:ok, %{status: :rejected, reason: "card_declined"}} =
             Auctions.place_bid(id, offer("ann", 500))

    assert_consistent(id)
  end

  test "a transient answer or a crashed task is asked again with the same bid id" do
    id = open_auction()

    Memory.script(fn
      _request, 1 -> {:transient, :rate_limited}
      _request, 2 -> :crash
      _request, _ -> :approve
    end)

    server = server(id)

    assert {:ok, %{status: :accepted, id: bid_id}} =
             Auctions.place_bid(id, offer("ann", 500), deadline_ms: 3_000)

    assert Memory.calls(bid_id) == 3
    assert Auctions.whereis(id) == server
    assert_consistent(id)
  end

  test "a restart decides a hold already in the log without asking the provider" do
    id = Ecto.UUID.generate()
    created = struct!(Event.AuctionCreated, params())

    log = [
      created,
      %Event.BidPlaced{bid_id: "b1", user_id: "ann", amount: 500, idempotency_key: "k"},
      %Event.HoldAuthorized{bid_id: "b1", payment_intent_id: "pi_b1", amount_capturable: 500}
    ]

    {:ok, _} = EventStore.append(id, 1, Enum.map(log, &%Event{data: &1}))
    :ok = Auctions.ensure_started(id)

    eventually(fn -> Auctions.get_bid(id, "b1").status == :accepted end)
    assert Memory.calls("b1") == 0
    assert_consistent(id)
  end

  test "an auction that doesn't exist starts nothing" do
    assert Auctions.ensure_started(Ecto.UUID.generate()) == {:error, :not_found}
    assert DynamicSupervisor.which_children(HoldfastEx.AuctionSupervisors) == []
  end
end
