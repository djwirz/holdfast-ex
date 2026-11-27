defmodule HoldfastEx.Repo.Migrations.CreateEventLog do
  use Ecto.Migration

  def change do
    # The log is the state (ADR 0003). The primary key is the single-writer
    # guarantee (ADR 0005).
    create table(:auction_events, primary_key: false) do
      add :auction_id, :uuid, primary_key: true
      add :seq, :bigint, primary_key: true
      add :type, :text, null: false
      add :v, :integer, null: false
      add :data, :map, null: false
      add :inserted_at, :timestamptz, null: false
    end

    create table(:bid_keys, primary_key: false) do
      add :user_id, :text, null: false
      add :idempotency_key, :text, null: false
      add :bid_id, :text, null: false
      add :auction_id, :uuid, null: false
      add :amount, :bigint, null: false
    end

    create unique_index(:bid_keys, [:user_id, :idempotency_key])
  end
end
