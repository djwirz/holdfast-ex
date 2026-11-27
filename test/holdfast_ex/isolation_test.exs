defmodule HoldfastEx.IsolationTest do
  @moduledoc "One auction crashing over and over leaves the others alone (ADR 0016)."
  use HoldfastEx.Test.DBCase, async: false

  alias HoldfastEx.Sweep

  @moduletag capture_log: true

  # Someone else writes the seq our server expects next, then it tries to.
  defp provoke_conflict(id, n) do
    with pid when pid != nil <- Auctions.whereis(id),
         %{core: core} <- safe_state(pid) do
      placed = %Event.BidPlaced{
        bid_id: "other-#{n}",
        user_id: "eve",
        amount: 1,
        idempotency_key: "other-#{n}"
      }

      rejected = %Event.BidRejected{bid_id: "other-#{n}", reason: :below_minimum}

      {:ok, _} =
        EventStore.append(id, core.version + 1, [%Event{data: placed}, %Event{data: rejected}])

      params = %{bid_id: "mine-#{n}", user_id: "ann", amount: 1, idempotency_key: "mine-#{n}"}
      monitor = Process.monitor(pid)
      assert {:conflict, _} = catch_exit(GenServer.call(pid, {:place_bid, params, 100}))
      assert_receive {:DOWN, ^monitor, :process, ^pid, :conflict}
      :crashed
    else
      _ -> :gone
    end
  end

  defp safe_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _ -> :gone
  end

  test "a burst of conflicts ends only its own auction's supervisor" do
    noisy = open_auction()
    quiet = open_auction()
    quiet_server = server(quiet)
    all = Process.whereis(HoldfastEx.AuctionSupervisors)
    [{supervisor, _}] = Registry.lookup(HoldfastEx.Registry, {:supervisor, noisy})
    monitor = Process.monitor(supervisor)

    crashes =
      Enum.reduce_while(1..30, 0, fn n, crashes ->
        # Between crashes the name is briefly free while the next server starts.
        eventually(fn -> Auctions.whereis(noisy) || not Process.alive?(supervisor) end)

        case provoke_conflict(noisy, n) do
          :crashed -> {:cont, crashes + 1}
          :gone -> {:halt, crashes}
        end
      end)

    # Ten restarts allowed, and the eleventh crash is one too many.
    assert crashes == 11
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}
    assert Process.whereis(HoldfastEx.AuctionSupervisors) == all
    assert Auctions.whereis(quiet) == quiet_server
    assert {:ok, %{status: :accepted}} = Auctions.place_bid(quiet, offer("ann", 500))

    # And the sweep brings the noisy one back.
    :ok = Sweep.run()
    assert {:ok, %{status: :accepted}} = Auctions.place_bid(noisy, offer("bob", 500))
    assert_consistent(noisy)
    assert_consistent(quiet)
  end
end
