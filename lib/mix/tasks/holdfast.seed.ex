defmodule Mix.Tasks.Holdfast.Seed do
  @shortdoc "Opens an auction and prints its id"
  @moduledoc """
  Opens an auction that ends after a while (spec §10), for local runs, the storm
  and the demo. It only writes the log: a running node's sweep, or the first
  request, starts the server.

      mix holdfast.seed --ends-in 300 --title "A synthetic lamp"
  """

  use Mix.Task

  alias HoldfastEx.Auctions

  @switches [ends_in: :integer, title: :string]

  @impl true
  def run(args) do
    {options, [], []} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")
    now = DateTime.utc_now()

    params = %{
      title: Keyword.get(options, :title, "A synthetic lamp"),
      starts_at: now,
      ends_at: DateTime.add(now, Keyword.get(options, :ends_in, 300), :second),
      starting_price: 1_000,
      min_increment: 100
    }

    {:ok, result, _} =
      Ecto.Migrator.with_repo(HoldfastEx.Repo, fn _ -> Auctions.record(params) end)

    {:ok, id} = result
    Mix.shell().info(id)
  end
end
