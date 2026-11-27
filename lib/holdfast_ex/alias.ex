defmodule HoldfastEx.Alias do
  @moduledoc """
  A bidder's public name in one auction (spec §6): an HMAC of auction and user, so
  it is stable within an auction, unlinkable across them, and nothing is stored.
  """

  @spec of(String.t(), String.t()) :: String.t()
  def of(auction_id, user_id) do
    key = Application.fetch_env!(:holdfast_ex, :alias_key)
    mac = :crypto.mac(:hmac, :sha256, key, [auction_id, ?:, user_id])
    "Bidder " <> Base.encode16(binary_part(mac, 0, 3), case: :lower)
  end
end
