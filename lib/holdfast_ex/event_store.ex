defmodule HoldfastEx.EventStore do
  @moduledoc """
  The append-only log in Postgres (ADRs 0003, 0005, 0007).

  An append names the seq it expects to write next. If another writer already
  wrote it, the primary key refuses the whole append. That, not any lock or
  registry, is what makes one writer per auction true (invariant 6).

  Database errors other than the ones named here raise: the writer can't know
  what was committed, so it should die and replay.
  """

  alias HoldfastEx.Event
  alias HoldfastEx.EventStore.Codec
  alias HoldfastEx.PublicView
  alias HoldfastEx.Repo

  @type key_row :: %{bid_id: String.t(), auction_id: Ecto.UUID.t(), amount: pos_integer()}

  @type append_error ::
          :conflict | {:key_used, key_row()} | {:past_end, database_now :: DateTime.t()}

  # One statement, so the guard and the rows can't part. now() is the database's
  # time for this transaction, and is both what the guard compares and what the
  # rows record, so an accepted bid's `inserted_at` is before `ends_at`.
  @insert_events """
  INSERT INTO auction_events (auction_id, seq, type, v, data, inserted_at)
  SELECT $1, e.seq, e.type, e.v, e.data, now()
  FROM unnest($2::bigint[], $3::text[], $4::integer[], $5::jsonb[]) AS e (seq, type, v, data)
  WHERE $6::timestamptz IS NULL OR now() < $6::timestamptz
  RETURNING inserted_at
  """

  @insert_key """
  INSERT INTO bid_keys (user_id, idempotency_key, bid_id, auction_id, amount)
  VALUES ($1, $2, $3, $4, $5)
  """

  @doc """
  Appends the events as seqs `next_seq`, `next_seq + 1`, ... in one transaction,
  and returns them stamped. Each `bid_placed` also claims its key in `bid_keys`.

  An append holding a `bid_accepted` must pass `ends_at:`, and is refused if the
  database's time is at or past it.
  """
  @spec append(Ecto.UUID.t(), pos_integer(), [Event.t()], keyword()) ::
          {:ok, [Event.t()]} | {:error, append_error()}
  def append(auction_id, next_seq, events, opts \\ [])
  def append(_auction_id, _next_seq, [], _opts), do: {:ok, []}

  def append(auction_id, next_seq, events, opts) do
    ends_at = opts[:ends_at]

    if is_nil(ends_at) and Enum.any?(events, &match?(%{data: %Event.BidAccepted{}}, &1)) do
      raise ArgumentError, "appending a bid_accepted needs ends_at:"
    end

    id = Ecto.UUID.dump!(auction_id)
    events = Enum.with_index(events, &%{&1 | seq: next_seq + &2})

    result =
      Repo.transact(fn ->
        with :ok <- claim_keys(id, events),
             {:ok, at} <- insert_events(id, events, ends_at) do
          {:ok, Enum.map(events, &%{&1 | at: at})}
        end
      end)

    case result do
      {:error, {:key_taken, placed}} ->
        {:error, {:key_used, lookup_key(placed.user_id, placed.idempotency_key)}}

      other ->
        other
    end
  end

  defp claim_keys(id, events) do
    placed = for %{data: %Event.BidPlaced{} = placed} <- events, do: placed

    Enum.reduce_while(placed, :ok, fn bid, :ok ->
      params = [bid.user_id, bid.idempotency_key, bid.bid_id, id, bid.amount]

      case Repo.query(@insert_key, params) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, error} ->
          unique!(error, "bid_keys_user_id_idempotency_key_index")
          {:halt, {:error, {:key_taken, bid}}}
      end
    end)
  end

  defp insert_events(id, events, ends_at) do
    {types, data} = events |> Enum.map(&Codec.encode(&1.data)) |> Enum.unzip()
    params = [id, Enum.map(events, & &1.seq), types, Enum.map(events, & &1.v), data, ends_at]

    case Repo.query(@insert_events, params) do
      {:ok, %{rows: [[at] | _]}} ->
        {:ok, at}

      {:ok, %{rows: []}} ->
        %{rows: [[now]]} = Repo.query!("SELECT now()")
        {:error, {:past_end, now}}

      {:error, error} ->
        unique!(error, "auction_events_pkey")
        {:error, :conflict}
    end
  end

  # Returns if the error is that constraint's unique violation, and raises if not.
  defp unique!(%Postgrex.Error{postgres: %{code: :unique_violation, constraint: name}}, name),
    do: :ok

  defp unique!(error, _name), do: raise(error)

  @doc "An auction's whole log, in seq order."
  @spec load(Ecto.UUID.t()) :: [Event.t()]
  def load(auction_id), do: select("WHERE auction_id = $1", [Ecto.UUID.dump!(auction_id)])

  defp select(where, params) do
    %{rows: rows} =
      Repo.query!(
        "SELECT seq, type, v, data, inserted_at FROM auction_events #{where} ORDER BY seq",
        params
      )

    Enum.map(rows, fn [seq, type, v, data, at] ->
      %Event{seq: seq, at: at, v: v, data: Codec.decode(type, v, data)}
    end)
  end

  @doc "Only the events that change what the public sees."
  @spec load_public(Ecto.UUID.t()) :: [Event.t()]
  def load_public(auction_id) do
    select(
      "WHERE auction_id = $1 AND type IN " <>
        "('auction_created', 'bid_accepted', 'auction_closed', 'capture_succeeded')",
      [Ecto.UUID.dump!(auction_id)]
    )
  end

  @doc "One bid's events, with every accept and close that can change its status."
  @spec load_bid(Ecto.UUID.t(), String.t()) :: [Event.t()]
  def load_bid(auction_id, bid_id) do
    select(
      "WHERE auction_id = $1 AND (data ->> 'bid_id' = $2 " <>
        "OR type IN ('bid_accepted', 'auction_closed'))",
      [Ecto.UUID.dump!(auction_id), bid_id]
    )
  end

  @doc "Whose bid it is and in which auction, or nil."
  @spec bid_owner(String.t()) :: %{user_id: String.t(), auction_id: Ecto.UUID.t()} | nil
  def bid_owner(bid_id) do
    case Repo.query!("SELECT user_id, auction_id FROM bid_keys WHERE bid_id = $1", [bid_id]) do
      %{rows: [[user_id, auction_id]]} ->
        %{user_id: user_id, auction_id: Ecto.UUID.load!(auction_id)}

      %{rows: []} ->
        nil
    end
  end

  # Live, upcoming, and ended within the last day (spec §6). Read from the log:
  # there are no projections (ADR 0003).
  @auctions """
  SELECT c.auction_id, c.data ->> 'title', (c.data ->> 'starts_at')::timestamptz,
         (c.data ->> 'ends_at')::timestamptz,
         EXISTS (SELECT 1 FROM auction_events e
                 WHERE e.auction_id = c.auction_id AND e.type = 'auction_closed'),
         EXISTS (SELECT 1 FROM auction_events e
                 WHERE e.auction_id = c.auction_id AND e.type = 'capture_succeeded'),
         (SELECT (e.data ->> 'amount')::bigint FROM auction_events e
          WHERE e.auction_id = c.auction_id AND e.type = 'bid_accepted'
          ORDER BY e.seq DESC LIMIT 1),
         now()
  FROM auction_events c
  WHERE c.type = 'auction_created'
    AND (c.data ->> 'ends_at')::timestamptz > now() - interval '1 day'
  ORDER BY 4 DESC
  LIMIT 50
  """

  @spec list_auctions() :: [map()]
  def list_auctions do
    %{rows: rows} = Repo.query!(@auctions)

    Enum.map(rows, fn [id, title, starts_at, ends_at, closed?, captured?, high, now] ->
      %{
        id: Ecto.UUID.load!(id),
        title: title,
        status: PublicView.status(closed?, captured?, starts_at, now),
        endsAt: PublicView.time(ends_at),
        currentHigh: high
      }
    end)
  end

  @spec exists?(Ecto.UUID.t()) :: boolean()
  def exists?(auction_id) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM auction_events WHERE auction_id = $1)", [
        Ecto.UUID.dump!(auction_id)
      ])

    exists
  end

  @doc "The bid a user's idempotency key made, in whichever auction, or nil."
  @spec lookup_key(String.t(), String.t()) :: key_row() | nil
  def lookup_key(user_id, idempotency_key) do
    %{rows: rows} =
      Repo.query!(
        "SELECT bid_id, auction_id, amount FROM bid_keys " <>
          "WHERE user_id = $1 AND idempotency_key = $2",
        [user_id, idempotency_key]
      )

    case rows do
      [[bid_id, auction_id, amount]] ->
        %{bid_id: bid_id, auction_id: Ecto.UUID.load!(auction_id), amount: amount}

      [] ->
        nil
    end
  end

  # Unfinished (ADRs 0014, 0015): not closed, or closed with a winner not yet
  # captured, or holding a bid with no outcome. A bid gets one outcome at most
  # (invariant 5), so fewer outcomes than bids means one is still open.
  @unfinished """
  SELECT c.auction_id FROM auction_events c
  WHERE c.type = 'auction_created'
    AND (
      NOT EXISTS (
        SELECT 1 FROM auction_events f
        WHERE f.auction_id = c.auction_id
          AND (f.type = 'capture_succeeded'
            OR (f.type = 'auction_closed' AND f.data ->> 'winner_bid_id' IS NULL))
      )
      OR (
        SELECT count(*) FILTER (WHERE b.type = 'bid_placed')
             > count(*) FILTER (WHERE b.type IN ('bid_accepted', 'bid_rejected', 'bid_lost'))
        FROM auction_events b
        WHERE b.auction_id = c.auction_id
      )
    )
  """

  @doc "The auctions that need a running server."
  @spec unfinished_ids() :: [Ecto.UUID.t()]
  def unfinished_ids do
    %{rows: rows} = Repo.query!(@unfinished)
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end
end
