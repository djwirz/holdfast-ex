defmodule HoldfastEx.AuctionPropertyTest do
  @moduledoc """
  The main correctness evidence (ADR 0004, spec §10): random bids, authorization
  results in any order, times around `ends_at`, repeated keys, and crashes that
  cut the log anywhere. After every step the log has to satisfy the invariants.

  `PROPERTY_RUNS` raises the number of runs. A failure prints the seed:
  `mix test --seed N` reproduces it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias HoldfastEx.Auction
  alias HoldfastEx.Event
  alias HoldfastEx.Invariants
  alias HoldfastEx.Test.Log
  alias HoldfastEx.Test.World

  @runs String.to_integer(System.get_env("PROPERTY_RUNS", "1000"))

  @tag timeout: :infinity
  test "invariants 1, 2, 3 and 5 hold over every log, through any crash" do
    # check/all runs in this process, so the counts can live in its dictionary.
    Process.put(:counts, %{})

    check all start <- World.start_ms(),
              actions <- World.actions(),
              # Given inline: `check all` reads a variable or attribute here as a filter.
              max_runs: @runs,
              initial_size: 10,
              # The default of 100 can leave a long counterexample.
              max_shrinking_steps: 5_000 do
      world =
        Enum.reduce(actions, World.new(start), fn action, world ->
          world = World.step(world, action)
          assert_sound(world)
          world
        end)

      count(world.seen)
    end

    report(Process.get(:counts))
  end

  @tag timeout: :infinity
  property "replaying a key or a result never adds a bid or a hold" do
    check all start <- World.start_ms(),
              actions <- World.actions(),
              # Given inline: `check all` reads a variable or attribute here as a filter.
              max_runs: @runs,
              initial_size: 10,
              # The default of 100 can leave a long counterexample.
              max_shrinking_steps: 5_000 do
      world = Enum.reduce(actions, World.new(start), &World.step(&2, &1))

      for {bid_id, bid} <- world.state.bids do
        same = Log.bid("new", bid.user_id, bid.amount, bid.idempotency_key)
        changed = Log.bid("new", bid.user_id, bid.amount + 1, bid.idempotency_key)

        assert World.decide(world, same) == {:error, {:duplicate, bid_id}}
        assert World.decide(world, changed) == {:error, :key_reused}

        if bid.status in [:accepted, :rejected, :lost] do
          late = Log.authorized(bid_id, bid.amount)
          assert World.decide(world, late) == {:ok, []}
        end
      end
    end
  end

  defp assert_sound(world) do
    assert Invariants.check(world.log) == []

    # Replay gives the state the live fold has.
    assert Auction.replay(world.log) == world.state

    # ADR 0013: the latest public event's seq, found the long way.
    last_public =
      world.log
      |> Enum.filter(
        &match?(%{data: %type{}} when type in [Event.BidAccepted, Event.AuctionClosed], &1)
      )
      |> List.last(%{seq: 0})

    assert world.state.last_public_seq == last_public.seq
    assert world.state.version == length(world.log)
  end

  defp count(seen) do
    counts =
      [:runs | MapSet.to_list(seen)]
      |> Enum.reduce(Process.get(:counts), &Map.update(&2, &1, 1, fn n -> n + 1 end))

    Process.put(:counts, counts)
  end

  # Passing over runs that never reach the hard cases would prove little.
  defp report(counts) do
    lines =
      for situation <- World.situations() do
        "  #{String.pad_trailing(to_string(situation), 32)} #{Map.get(counts, situation, 0)}"
      end

    assert counts.runs == @runs

    IO.puts("\nSituations reached, in runs out of #{counts.runs}:\n" <> Enum.join(lines, "\n"))

    missed = Enum.reject(World.situations(), &Map.has_key?(counts, &1))
    assert missed == [], "the generators never reached #{inspect(missed)}"
  end
end
