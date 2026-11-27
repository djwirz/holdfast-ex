defmodule HoldfastEx.AuctionSupervisor do
  @moduledoc """
  One small supervisor for one auction's server (ADR 0016).

  Restart limits are counted by a supervisor, across all its children. Giving
  each auction its own means one that keeps crashing uses up only its own: this
  supervisor gives up and exits, and since it is `:temporary` above, nothing else
  notices. The sweep starts it again later.

  The server is `significant`, so when it stops normally (idle, or no such
  auction) this supervisor goes with it.
  """

  use Supervisor, restart: :temporary

  alias HoldfastEx.Auctions
  alias HoldfastEx.AuctionServer

  @max_restarts 10
  @max_seconds 5

  @doc "Takes `HoldfastEx.AuctionServer`'s options."
  def start_link(opts) do
    id = Keyword.fetch!(opts, :auction_id)
    Supervisor.start_link(__MODULE__, opts, name: Auctions.supervisor_name(id))
  end

  @impl true
  def init(opts) do
    children = [Supervisor.child_spec({AuctionServer, opts}, significant: true)]

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
