defmodule HoldfastEx.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    # Plain tables: sign-in isn't auction state (ADR 0003). Card columns come with
    # Stripe (slice 4).
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :login, :text, null: false
      add :dev, :boolean, null: false
    end

    create unique_index(:users, [:dev, :login])

    # Only the SHA-256 of the cookie's bytes is stored (spec §9).
    create table(:sessions, primary_key: false) do
      add :id, :binary, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :expires_at, :timestamptz, null: false
    end

    # A bid poll names only the bid: this finds its auction and owner (Q-A2).
    create index(:bid_keys, [:bid_id])
  end
end
