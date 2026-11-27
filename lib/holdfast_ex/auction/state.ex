defmodule HoldfastEx.Auction.State do
  @moduledoc """
  What an auction's log folds into. Only `HoldfastEx.Auction.apply/2` builds it.
  """

  alias HoldfastEx.Event

  defstruct auction: nil,
            version: 0,
            last_public_seq: 0,
            bids: %{},
            keys: %{},
            current_high: nil,
            closed: nil,
            released: MapSet.new(),
            capture: nil

  @typedoc "`:pending` and `:authorized` are unresolved; the other three are final."
  @type bid_status :: :pending | :authorized | :accepted | :rejected | :lost

  @type bid :: %{
          user_id: String.t(),
          amount: pos_integer(),
          idempotency_key: String.t(),
          status: bid_status(),
          reason: Event.BidRejected.reason() | Event.BidLost.reason() | nil,
          payment_intent_id: String.t() | nil,
          amount_capturable: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          auction: Event.AuctionCreated.t() | nil,
          version: non_neg_integer(),
          last_public_seq: non_neg_integer(),
          bids: %{optional(String.t()) => bid()},
          keys: %{optional({String.t(), String.t()}) => String.t()},
          current_high: %{bid_id: String.t(), amount: pos_integer(), alias: String.t()} | nil,
          closed: %{winner_bid_id: String.t() | nil} | nil,
          released: MapSet.t(String.t()),
          capture: :succeeded | {:failed, String.t()} | nil
        }
end
