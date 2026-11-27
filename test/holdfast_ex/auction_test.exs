defmodule HoldfastEx.AuctionTest do
  use ExUnit.Case, async: true

  import HoldfastEx.Test.Log

  alias HoldfastEx.Auction
  alias HoldfastEx.Event

  defp data({:ok, events}), do: Enum.map(events, & &1.data)

  defp decide({_log, state}, command, ms), do: Auction.decide(state, command, at(ms))

  defp open_with_high(amount) do
    created()
    |> run(bid("b1", "ann", amount), at(2_000))
    |> run(authorized("b1", amount), at(2_100))
  end

  describe "create" do
    test "refuses an auction over a day, or one that ends before it starts" do
      day = 24 * 60 * 60 * 1_000

      for ends_at <- [at(1_000), at(0), at(1_000 + day + 1)] do
        command = {:create, %{params() | ends_at: ends_at}}
        assert Auction.decide(Auction.new(), command, t0()) == {:error, :invalid_auction}
      end

      exactly_a_day = {:create, %{params() | ends_at: at(1_000 + day)}}
      assert {:ok, [_]} = Auction.decide(Auction.new(), exactly_a_day, t0())
    end

    test "refuses prices that aren't positive integers" do
      for change <- [%{starting_price: 0}, %{min_increment: 0}, %{starting_price: 5.0}] do
        command = {:create, Map.merge(params(), change)}
        assert Auction.decide(Auction.new(), command, t0()) == {:error, :invalid_auction}
      end
    end

    test "happens once, and nothing else happens before it" do
      assert decide(created(), {:create, params()}, 0) == {:error, :already_created}
      assert Auction.decide(Auction.new(), :close, t0()) == {:error, :not_found}
      assert Auction.decide(Auction.new(), bid("b1", "ann", 500), t0()) == {:error, :not_found}
    end
  end

  describe "minimum_next_bid" do
    test "is the starting price, then the high plus the increment, then nothing" do
      {_, state} = created()
      assert Auction.minimum_next_bid(state) == 500

      {_, state} = open_with_high(750)
      assert Auction.minimum_next_bid(state) == 850

      {_, state} = run(open_with_high(750), :close, at(61_000))
      assert Auction.minimum_next_bid(state) == nil
    end

    test "is not raised by a bid still pending" do
      {_, state} = run(created(), bid("b1", "ann", 900), at(2_000))
      assert Auction.minimum_next_bid(state) == 500
    end
  end

  describe "placing a bid" do
    test "a bid that passes the pre-check is only placed" do
      assert [%Event.BidPlaced{bid_id: "b1", amount: 500}] =
               data(decide(created(), bid("b1", "ann", 500), 1_000))
    end

    test "a refused bid is recorded with the rule that refused it" do
      for {amount, ms, reason} <- [
            {499, 2_000, :below_minimum},
            {500, 999, :not_open},
            {500, 61_000, :ended},
            # `ended` is reported ahead of the amount
            {1, 70_000, :ended}
          ] do
        assert [%Event.BidPlaced{}, %Event.BidRejected{reason: ^reason}] =
                 data(decide(created(), bid("b1", "ann", amount), ms))
      end
    end

    test "the last millisecond before ends_at still counts" do
      assert [%Event.BidPlaced{}] = data(decide(created(), bid("b1", "ann", 500), 60_999))
    end

    test "an amount that isn't a positive integer records nothing" do
      for amount <- [0, -5, 5.5, "500"] do
        assert decide(created(), bid("b1", "ann", amount), 2_000) == {:error, :invalid_bid}
      end
    end

    test "a repeated key answers with the original, or refuses a new amount" do
      world = run(created(), bid("b1", "ann", 500, "k"), at(2_000))

      assert decide(world, bid("b2", "ann", 500, "k"), 3_000) == {:error, {:duplicate, "b1"}}
      assert decide(world, bid("b2", "ann", 600, "k"), 3_000) == {:error, :key_reused}
      assert {:ok, [_]} = decide(world, bid("b2", "bob", 500, "k"), 3_000)
      assert decide(world, bid("b1", "ann", 500, "other"), 3_000) == {:error, :bid_id_taken}
    end
  end

  describe "an authorization result" do
    setup do
      %{world: run(created(), bid("b1", "ann", 600), at(2_000))}
    end

    test "records the hold, then accepts", %{world: world} do
      assert [
               %Event.HoldAuthorized{payment_intent_id: "pi_b1", amount_capturable: 600},
               %Event.BidAccepted{amount: 600, previous_high_bid_id: nil, alias: "alias-b1"}
             ] = data(decide(world, authorized("b1", 600), 3_000))
    end

    test "loses if it no longer qualifies", %{world: world} do
      assert [_, %Event.BidLost{reason: :ended}] =
               data(decide(world, authorized("b1", 600), 61_000))

      assert [_, %Event.BidLost{reason: :not_covered}] =
               data(decide(world, authorized("b1", 599), 3_000))

      assert [_, %Event.BidLost{reason: :not_open}] =
               data(decide(world, authorized("b1", 600), 999))

      closed = run(world, :close, at(61_000))
      # Even by a clock that says there's time left.
      assert [_, %Event.BidLost{reason: :ended}] =
               data(decide(closed, authorized("b1", 600), 3_000))
    end

    test "gives a tie to whichever comes back first", %{world: world} do
      world =
        world
        |> run(bid("b2", "bob", 600), at(2_001))
        |> run(authorized("b2", 600), at(2_500))

      assert [_, %Event.BidLost{reason: :below_minimum}] =
               data(decide(world, authorized("b1", 600), 2_600))
    end

    test "names the high it replaces", %{world: world} do
      world = run(world, authorized("b1", 600), at(2_100))
      world = run(world, bid("b2", "bob", 700), at(2_200))

      assert [_, %Event.BidAccepted{previous_high_bid_id: "b1"}] =
               data(decide(world, authorized("b2", 700), 2_300))
    end

    test "that failed rejects the bid with the reason", %{world: world} do
      for reason <- ["card_declined", :authentication_required, :processing_error] do
        assert [%Event.BidRejected{reason: ^reason}] =
                 data(decide(world, failed("b1", reason), 3_000))
      end
    end

    test "for a resolved bid adds nothing", %{world: world} do
      world = run(world, authorized("b1", 600), at(2_100))
      assert decide(world, authorized("b1", 600), 2_200) == {:ok, []}
      assert decide(world, failed("b1", "card_declined"), 2_200) == {:ok, []}
    end

    test "for an unknown bid is an error", %{world: world} do
      assert decide(world, authorized("nope", 600), 2_200) == {:error, :unknown_bid}
    end

    test "after a restart between hold and outcome, decides on the logged hold",
         %{world: {log, _} = world} do
      {full, _} = run(world, authorized("b1", 599), at(2_100))
      cut = Enum.take(full, length(log) + 1)

      # The replayed result claims more than the log recorded. The log wins.
      assert [%Event.BidLost{reason: :not_covered}] =
               data(Auction.decide(Auction.replay(cut), authorized("b1", 600), at(3_000)))
    end
  end

  describe "closing" do
    test "waits for ends_at" do
      assert decide(created(), :close, 60_999) == {:error, :not_due}

      assert [%Event.AuctionClosed{winner_bid_id: nil}] =
               data(decide(created(), :close, 61_000))
    end

    test "names the current high, once" do
      assert [%Event.AuctionClosed{winner_bid_id: "b1"}] =
               data(decide(open_with_high(500), :close, 61_000))

      closed = run(open_with_high(500), :close, at(61_000))
      assert decide(closed, :close, 62_000) == {:ok, []}
    end
  end

  describe "apply" do
    test "refuses a seq that isn't the next one" do
      {[first], state} = created()

      assert_raise FunctionClauseError, fn -> Auction.apply(state, first) end
      assert_raise FunctionClauseError, fn -> Auction.apply(state, %{first | seq: 3}) end
    end

    test "tracks the latest public event's seq" do
      assert {_, %{last_public_seq: 0}} = run(created(), bid("b1", "ann", 500), at(2_000))

      # created, placed, hold, accepted
      assert {_, %{last_public_seq: 4, version: 4} = state} = open_with_high(500)
      assert {_, %{last_public_seq: 4}} = run(open_with_high(500), bid("b2", "bob", 1), at(3_000))
      assert {_, %{last_public_seq: 5}} = run(open_with_high(500), :close, at(61_000))
      assert state.current_high == %{bid_id: "b1", amount: 500, alias: "alias-b1"}
    end

    test "folds the hold release and capture events" do
      {log, state} = run(open_with_high(500), :close, at(61_000))

      events = [
        %Event{data: %Event.HoldReleased{payment_intent_id: "pi_old"}},
        %Event{data: %Event.CaptureFailed{payment_intent_id: "pi_b1", reason: "network"}},
        %Event{data: %Event.CaptureSucceeded{payment_intent_id: "pi_b1"}}
      ]

      {_, folded} = append(log, state, events, at(62_000))

      assert MapSet.member?(folded.released, "pi_old")
      assert folded.capture == :succeeded
      assert folded.last_public_seq == state.last_public_seq
    end
  end
end
