defmodule HoldfastEx.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :holdfast_ex, adapter: Ecto.Adapters.Postgres
end
