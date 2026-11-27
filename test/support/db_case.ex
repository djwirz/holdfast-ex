defmodule HoldfastEx.Test.DBCase do
  @moduledoc """
  Tests against real Postgres, committing for real. There's no SQL sandbox: it
  wraps a test in one transaction, which would freeze the database's `now()` that
  the accept guard compares. So these tests run one at a time on empty tables.
  """

  use ExUnit.CaseTemplate

  alias HoldfastEx.Auction
  alias HoldfastEx.Auctions
  alias HoldfastEx.EventStore
  alias HoldfastEx.Invariants
  alias HoldfastEx.Payments.Memory
  alias HoldfastEx.Repo

  using do
    quote do
      import HoldfastEx.Test.DBCase

      alias HoldfastEx.Auction
      alias HoldfastEx.Auctions
      alias HoldfastEx.Event
      alias HoldfastEx.EventStore
      alias HoldfastEx.Payments.Memory
    end
  end

  setup tags do
    stop_auctions()
    Repo.query!("TRUNCATE auction_events, bid_keys, users, sessions")
    HoldfastEx.RateLimit.reset()
    Memory.reset()
    # Callbacks run last-first: stop the servers, then check what they left.
    if Map.get(tags, :check_logs, true), do: on_exit(&check_every_log/0)
    on_exit(&stop_auctions/0)
  end

  @doc "Invariants 1, 2, 3 and 5 over every log a test leaves behind."
  def check_every_log do
    %{rows: rows} = Repo.query!("SELECT DISTINCT auction_id FROM auction_events")

    for [id] <- rows, id = Ecto.UUID.load!(id) do
      assert {id, Invariants.check(EventStore.load(id))} == {id, []}
    end
  end

  def stop_auctions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HoldfastEx.AuctionSupervisors) do
      DynamicSupervisor.terminate_child(HoldfastEx.AuctionSupervisors, pid)
    end

    :ok
  end

  @doc """
  Params for an auction open now, 500 + 100, ending after `ends_in_ms`. It opened
  a while ago, so that a test's slow node clock still sees it open.
  """
  def params(ends_in_ms \\ 60_000) do
    now = DateTime.utc_now()

    %{
      title: "A synthetic lamp",
      starts_at: DateTime.add(now, -300, :second),
      ends_at: DateTime.add(now, ends_in_ms, :millisecond),
      starting_price: 500,
      min_increment: 100
    }
  end

  def open_auction(ends_in_ms \\ 60_000, opts \\ []) do
    {:ok, id} = Auctions.create(params(ends_in_ms), opts)
    id
  end

  def offer(user, amount, key \\ nil),
    do: %{user_id: user, amount: amount, idempotency_key: key || "key-#{user}-#{amount}"}

  def data(auction_id), do: Enum.map(EventStore.load(auction_id), & &1.data)

  def count(auction_id, module),
    do: Enum.count(data(auction_id), &(&1.__struct__ == module))

  @doc "The running server's pid, once it has replayed."
  def server(auction_id) do
    pid = eventually(fn -> Auctions.whereis(auction_id) end)
    _ = :sys.get_state(pid)
    pid
  end

  @doc "Retries until `fun` returns something truthy."
  def eventually(fun, tries \\ 300) do
    cond do
      value = fun.() -> value
      tries == 0 -> raise "it never happened"
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  @doc """
  The log satisfies invariants 1, 2, 3 and 5, and a running server's state is
  exactly the replay of it (invariant 6).
  """
  def assert_consistent(auction_id) do
    # Let a server finish what it is doing before reading both.
    core =
      case Auctions.whereis(auction_id) do
        nil -> nil
        pid -> :sys.get_state(pid).core
      end

    events = EventStore.load(auction_id)
    assert Invariants.check(events) == []
    if core, do: assert(core == Auction.replay(events))
  end

  @doc """
  Runs `fun` inside the server process at that step of that auction. The server's
  steps are telemetry events, and handlers run in the process that emits them.
  """
  def on_step(auction_id, step, fun) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:holdfast_ex, :auction, step],
        &__MODULE__.handle_step/4,
        {auction_id, fun}
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_step(_event, _measurements, %{auction_id: id}, {id, fun}), do: fun.()
  def handle_step(_event, _measurements, _metadata, _config), do: :ok

  @doc "A function that runs `fun` only the first time it is called."
  def once(fun) do
    flag = :atomics.new(1, [])
    fn -> if :atomics.exchange(flag, 1, 1) == 0, do: fun.() end
  end

  @doc "Kills the server the first time it reaches the step."
  def kill_at(auction_id, step),
    do: on_step(auction_id, step, once(fn -> Process.exit(self(), :kill) end))

  @doc """
  Stops the server the first time it reaches the step, until `resume/1`. The
  test gets `{:paused, pid}`.
  """
  def pause_at(auction_id, step) do
    test = self()

    on_step(
      auction_id,
      step,
      once(fn ->
        send(test, {:paused, self()})

        receive do
          :resume -> :ok
        end
      end)
    )
  end

  def resume(pid), do: send(pid, :resume)
end
