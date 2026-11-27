defmodule HoldfastEx.PublicView do
  @moduledoc """
  What the contract shows (spec §6), as a second pure fold over the log.

  The auction server folds it to publish and to write the snapshot, and reads fold
  the same events from the log. So an event is the same whether it arrives live or
  is read later. Folding only the public types gives the same events and bids, but
  not the auction's version, which any event moves.
  """

  alias HoldfastEx.Event

  @recent 20

  defstruct id: nil,
            auction: nil,
            version: 0,
            last_public_seq: 0,
            high: nil,
            recent: [],
            closed?: false,
            captured?: false

  @type public_bid :: %{
          version: pos_integer(),
          amount: pos_integer(),
          bidder: String.t(),
          at: String.t()
        }

  @typedoc "An SSE event's data. `type` is also its event name, `version` its id."
  @type public_event :: %{
          required(:type) => String.t(),
          required(:version) => pos_integer(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{}

  @type bid :: %{
          id: String.t(),
          auctionId: String.t(),
          amount: pos_integer(),
          status: String.t(),
          reason: String.t() | nil,
          createdAt: String.t(),
          resolvedAt: String.t() | nil
        }

  @spec new(String.t()) :: t()
  def new(auction_id), do: %__MODULE__{id: auction_id}

  @doc """
  Folds events, and returns the public ones among them, each with the seq of the
  public event before it (ADR 0013).
  """
  @spec fold(t(), [Event.t()]) :: {t(), [{non_neg_integer(), public_event()}]}
  def fold(%__MODULE__{} = view, events) do
    {view, published} =
      Enum.reduce(events, {view, []}, fn event, {view, published} ->
        previous = view.last_public_seq
        view = step(%{view | version: event.seq}, event)

        if Event.public?(event) do
          view = %{view | last_public_seq: event.seq}
          {view, [{previous, public_event(view, event)} | published]}
        else
          {view, published}
        end
      end)

    {view, Enum.reverse(published)}
  end

  defp step(view, %{data: %Event.AuctionCreated{} = created}), do: %{view | auction: created}

  defp step(view, %{data: %Event.BidAccepted{} = accepted} = event) do
    bid = %{
      version: event.seq,
      amount: accepted.amount,
      bidder: accepted.alias,
      at: time(event.at)
    }

    %{view | high: bid, recent: Enum.take([bid | view.recent], @recent)}
  end

  defp step(view, %{data: %Event.AuctionClosed{}}), do: %{view | closed?: true}
  defp step(view, %{data: %Event.CaptureSucceeded{}}), do: %{view | captured?: true}
  defp step(view, _event), do: view

  defp public_event(view, %{data: %Event.BidAccepted{}}),
    do: Map.put(view.high, :type, "bid.accepted")

  # Always `closed`, even once the snapshot says `settled`.
  defp public_event(view, %{data: %Event.AuctionClosed{}} = event) do
    %{
      type: "auction.closed",
      version: event.seq,
      status: "closed",
      winner: view.high && view.high.bidder,
      amount: view.high && view.high.amount
    }
  end

  @doc "The snapshot of `GET /api/auctions/:id`. `you` is the caller's alias."
  @spec snapshot(t(), DateTime.t(), String.t() | nil) :: map()
  def snapshot(%__MODULE__{auction: %{} = auction} = view, now, you) do
    %{
      auction: %{
        id: view.id,
        title: auction.title,
        status: status(view.closed?, view.captured?, auction.starts_at, now),
        startsAt: time(auction.starts_at),
        endsAt: time(auction.ends_at),
        startingPrice: auction.starting_price,
        minIncrement: auction.min_increment,
        version: view.version,
        minimumNextBid: minimum_next_bid(view)
      },
      currentHigh: view.high,
      recentBids: view.recent,
      you: you
    }
  end

  @doc "`scheduled`, `open`, `closed` or `settled`."
  @spec status(boolean(), boolean(), DateTime.t(), DateTime.t()) :: String.t()
  def status(_closed?, true, _starts_at, _now), do: "settled"
  def status(true, false, _starts_at, _now), do: "closed"

  def status(false, false, starts_at, now),
    do: if(DateTime.before?(now, starts_at), do: "scheduled", else: "open")

  defp minimum_next_bid(%{closed?: true}), do: nil
  defp minimum_next_bid(%{high: nil, auction: auction}), do: auction.starting_price
  defp minimum_next_bid(%{high: high, auction: auction}), do: high.amount + auction.min_increment

  @doc """
  A bid as its own bidder sees it, or nil if the events don't hold it. They must
  include its own, and every accept and close of the auction.
  """
  @spec bid([Event.t()], String.t(), String.t()) :: bid() | nil
  def bid(events, auction_id, bid_id) do
    Enum.reduce(events, nil, fn event, bid -> bid_step(event, bid, auction_id, bid_id) end)
  end

  defp bid_step(%{data: %Event.BidPlaced{bid_id: id} = placed} = event, nil, auction_id, id) do
    %{
      id: id,
      auctionId: auction_id,
      amount: placed.amount,
      status: "pending",
      reason: nil,
      createdAt: time(event.at),
      resolvedAt: nil
    }
  end

  defp bid_step(_event, nil, _auction_id, _bid_id), do: nil

  defp bid_step(%{data: %Event.BidAccepted{bid_id: id}} = event, bid, _auction_id, id),
    do: %{bid | status: "accepted", resolvedAt: time(event.at)}

  defp bid_step(%{data: %Event.BidAccepted{}}, %{status: "accepted"} = bid, _, _),
    do: %{bid | status: "outbid"}

  defp bid_step(%{data: %Event.BidRejected{bid_id: id} = out} = event, bid, _, id),
    do: %{bid | status: "rejected", reason: to_string(out.reason), resolvedAt: time(event.at)}

  defp bid_step(%{data: %Event.BidLost{bid_id: id} = out} = event, bid, _, id),
    do: %{bid | status: "lost_race", reason: to_string(out.reason), resolvedAt: time(event.at)}

  defp bid_step(%{data: %Event.AuctionClosed{winner_bid_id: id}}, bid, _, id),
    do: %{bid | status: "won"}

  defp bid_step(_event, bid, _auction_id, _bid_id), do: bid

  @doc "ISO 8601 to the millisecond."
  @spec time(DateTime.t()) :: String.t()
  def time(%DateTime{} = time),
    do: time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
