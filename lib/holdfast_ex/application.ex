defmodule HoldfastEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HoldfastEx.Repo,
      {Registry, keys: :unique, name: HoldfastEx.Registry},
      {Task.Supervisor, name: HoldfastEx.TaskSupervisor},
      # The only payment adapter until slice 4.
      HoldfastEx.Payments.Memory,
      {DynamicSupervisor, name: HoldfastEx.AuctionSupervisors},
      {HoldfastEx.Sweep,
       name: HoldfastEx.Sweep,
       interval_ms: Application.fetch_env!(:holdfast_ex, :sweep_interval_ms)}
    ]

    # Each child leans on the ones before it: if one is restarted, so are the
    # ones after it.
    Supervisor.start_link(children, strategy: :rest_for_one, name: HoldfastEx.Supervisor)
  end
end
