defmodule Mix.Tasks.Holdfast.Check do
  @shortdoc "Checks the invariants over one auction's log"
  @moduledoc """
  Waits for an auction to close with no bid pending, then applies the invariants
  (spec §7) to its log. Fails on a violation, or if nothing was accepted.

      mix holdfast.check AUCTION_ID --wait 60

  Slice 4 adds invariant 4, from the payment fake's own record.
  """

  use Mix.Task

  alias HoldfastEx.Event
  alias HoldfastEx.EventStore
  alias HoldfastEx.Invariants

  @impl true
  def run(args) do
    {options, [id], []} = OptionParser.parse(args, strict: [wait: :integer])
    Mix.Task.run("app.config")
    deadline = System.monotonic_time(:second) + Keyword.get(options, :wait, 60)

    {:ok, events, _} =
      Ecto.Migrator.with_repo(HoldfastEx.Repo, fn _ -> settled(id, deadline) end)

    count = fn module -> Enum.count(events, &is_struct(&1.data, module)) end

    Mix.shell().info(
      "events: #{length(events)}, bids: #{count.(Event.BidPlaced)}, " <>
        "accepted: #{count.(Event.BidAccepted)}, rejected: #{count.(Event.BidRejected)}, " <>
        "lost: #{count.(Event.BidLost)}"
    )

    violations = Invariants.check(events)
    Enum.each(violations, &Mix.shell().error(inspect(&1)))

    cond do
      violations != [] -> Mix.raise("#{length(violations)} invariant violations")
      count.(Event.BidAccepted) == 0 -> Mix.raise("nothing was accepted")
      true -> Mix.shell().info("invariants 1, 2, 3 and 5 hold")
    end
  end

  # Idle: closed, and every bid placed has its outcome.
  defp settled(id, deadline) do
    events = EventStore.load(id)
    count = fn modules -> Enum.count(events, &(&1.data.__struct__ in modules)) end
    outcomes = [Event.BidAccepted, Event.BidRejected, Event.BidLost]

    cond do
      count.([Event.AuctionClosed]) == 1 and count.([Event.BidPlaced]) == count.(outcomes) ->
        events

      System.monotonic_time(:second) > deadline ->
        Mix.raise("the auction didn't settle in time")

      true ->
        Process.sleep(500)
        settled(id, deadline)
    end
  end
end
