defmodule HoldfastEx.EventStoreTest do
  use HoldfastEx.Test.DBCase, async: false
  use ExUnitProperties

  alias HoldfastEx.EventStore.Codec
  alias HoldfastEx.Test.World

  # These write logs by hand, many of them ones no server would produce.
  @moduletag check_logs: false

  defp created, do: struct!(Event.AuctionCreated, params())

  defp events(data), do: Enum.map(data, &%Event{data: &1})

  defp placed(bid_id, user \\ "ann", key \\ nil) do
    %Event.BidPlaced{
      bid_id: bid_id,
      user_id: user,
      amount: 500,
      idempotency_key: key || "key-#{bid_id}"
    }
  end

  defp held(bid_id),
    do: %Event.HoldAuthorized{
      bid_id: bid_id,
      payment_intent_id: "pi_#{bid_id}",
      amount_capturable: 500
    }

  defp accepted(bid_id),
    do: %Event.BidAccepted{bid_id: bid_id, amount: 500, alias: "a", previous_high_bid_id: nil}

  defp new_auction do
    id = Ecto.UUID.generate()
    {:ok, _} = EventStore.append(id, 1, events([created()]))
    id
  end

  test "appends consecutive seqs, stamped with the database's time, and loads them back" do
    id = new_auction()
    {:ok, appended} = EventStore.append(id, 2, events([placed("b1"), held("b1")]))

    assert [%{seq: 2, at: at}, %{seq: 3, at: at}] = appended
    assert [%{seq: 1}, second, third] = EventStore.load(id)
    assert [second, third] == appended
    assert EventStore.exists?(id)
    refute EventStore.exists?(Ecto.UUID.generate())
  end

  describe "the two conflicts" do
    test "a seq already written refuses the whole append, key and all" do
      id = new_auction()
      {:ok, _} = EventStore.append(id, 2, events([placed("b1")]))

      assert EventStore.append(id, 2, events([placed("b2", "bob")])) == {:error, :conflict}
      assert EventStore.lookup_key("bob", "key-b2") == nil
      assert count(id, Event.BidPlaced) == 1
    end

    test "a used key is told apart, names the original, and writes nothing" do
      id = new_auction()
      other = new_auction()
      {:ok, _} = EventStore.append(id, 2, events([placed("b1", "ann", "k")]))

      assert {:error, {:key_used, %{bid_id: "b1", auction_id: ^id, amount: 500}}} =
               EventStore.append(other, 2, events([placed("b2", "ann", "k")]))

      assert length(EventStore.load(other)) == 1
      # Another user's same key is theirs.
      assert {:ok, _} = EventStore.append(other, 2, events([placed("b3", "bob", "k")]))
    end
  end

  describe "the database-time guard (ADR 0007)" do
    test "refuses an accept at or after ends_at, writing nothing, and says the time" do
      id = new_auction()
      ends_at = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:error, {:past_end, now}} =
               EventStore.append(id, 2, events([held("b1"), accepted("b1")]), ends_at: ends_at)

      refute DateTime.before?(now, ends_at)
      assert length(EventStore.load(id)) == 1
    end

    test "lets one through before ends_at, recording a time before it" do
      id = new_auction()
      ends_at = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, [_, %{at: at}]} =
               EventStore.append(id, 2, events([held("b1"), accepted("b1")]), ends_at: ends_at)

      assert DateTime.before?(at, ends_at)
    end

    test "can't be left off an accept" do
      assert_raise ArgumentError, fn ->
        EventStore.append(new_auction(), 2, events([accepted("b1")]))
      end
    end
  end

  test "unfinished: open, closed with an uncaptured winner, or with a bid unresolved" do
    closed = &%Event.AuctionClosed{winner_bid_id: &1}
    rejected = &%Event.BidRejected{bid_id: &1, reason: :ended}

    log = fn data ->
      id = new_auction()
      {:ok, _} = EventStore.append(id, 2, events(data))
      id
    end

    open = new_auction()
    winner = log.([closed.("b1")])
    in_flight = log.([placed("p1"), closed.(nil)])
    _no_winner = log.([closed.(nil)])
    _all_resolved = log.([placed("r1"), rejected.("r1"), closed.(nil)])
    _captured = log.([closed.("b9"), %Event.CaptureSucceeded{payment_intent_id: "pi"}])

    assert Enum.sort(EventStore.unfinished_ids()) == Enum.sort([open, winner, in_flight])
  end

  describe "the codec" do
    test "keeps a decline code apart from the rule spelled the same" do
      for reason <- [
            :processing_error,
            "processing_error",
            :authentication_required,
            "authentication_required"
          ] do
        event = %Event.BidRejected{bid_id: "b1", reason: reason}
        {type, fields} = Codec.encode(event)
        stored = fields |> JSON.encode!() |> JSON.decode!()
        assert Codec.decode(type, 1, stored) == event
      end
    end

    test "round-trips the events the core has no command for yet" do
      for event <- [
            %Event.HoldReleased{payment_intent_id: "pi"},
            %Event.CaptureSucceeded{payment_intent_id: "pi"},
            %Event.CaptureFailed{payment_intent_id: "pi", reason: "card_declined"}
          ] do
        {type, fields} = Codec.encode(event)
        assert Codec.decode(type, 1, fields |> JSON.encode!() |> JSON.decode!()) == event
      end
    end

    property "any log the core produces reads back from Postgres as it was written" do
      check all(
              start <- World.start_ms(),
              actions <- World.actions(),
              max_runs: 50
            ) do
        world = Enum.reduce(actions, World.new(start), &World.step(&2, &1))
        id = Ecto.UUID.generate()

        # Keys are unique across auctions, so give each run its own.
        written =
          Enum.map(world.log, fn
            %{data: %Event.BidPlaced{} = placed} = event ->
              %{event | data: %{placed | idempotency_key: "#{id}/#{placed.idempotency_key}"}}

            event ->
              event
          end)

        {:ok, _} = EventStore.append(id, 1, written, ends_at: ~U[2100-01-01 00:00:00Z])
        read = EventStore.load(id)

        assert Enum.map(read, & &1.data) == Enum.map(written, & &1.data)
        assert Enum.map(read, & &1.seq) == Enum.map(written, & &1.seq)
      end
    end
  end
end
