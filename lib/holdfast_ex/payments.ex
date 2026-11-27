defmodule HoldfastEx.Payments do
  @moduledoc """
  What the auction asks of a payment provider (spec §4). Only authorizing so far:
  cancel and capture arrive with HoldKeeper, and the Stripe adapters and their
  error taxonomy with slice 4.
  """

  alias HoldfastEx.Auction

  @type request :: %{
          auction_id: Ecto.UUID.t(),
          bid_id: String.t(),
          user_id: String.t(),
          amount: pos_integer()
        }

  @doc """
  Places a hold for one bid. The bid id is the idempotency key: asking again
  gives the same hold. `{:transient, reason}` means ask again with the same key.
  """
  @callback authorize(request()) :: Auction.authorization_result() | {:transient, term()}
end
